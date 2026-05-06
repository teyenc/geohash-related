-- ============================================================================
-- cgeo_text_helpers.sql
--
-- Text-API replacement for the (now-removed) int64 cgeo_spatial_candidates /
-- create_cgeo_spatial_index helpers. We store cell IDs as right-padded
-- 10-char base32 geohash strings (canonical geohash encoding) instead of
-- int64s, and run BETWEEN range scans on the indexed text column.
--
-- Architecture:
--   * Mapping table: <table>_cgeo_index(id int8, geohash text NOT NULL,
--                    PRIMARY KEY (geohash ASC, id))
--     We pick a fixed `index_precision` per indexed table (e.g. 10 for points,
--     5 for lines/polygons) and pad every stored cell to 10 chars with '0'.
--   * Query side: c_geohash_l10_ranges_merged(bbox, query_precision) returns
--     (min10, max10) text pairs. For each pair we issue ONE B-tree range
--     scan via BETWEEN. UNION ALL across pairs (YB lacks BitmapOr; a single
--     OR would degrade to Seq Scan).
--
-- IMPORTANT precision constraint: query_precision <= index_precision.
-- Because we right-pad with '0' there is no level marker stored — a coarse
-- cell '9q' indexed as '9q00000000' lex-compares EQUAL to a level-10 cell at
-- the western corner of '9q'. Querying at a finer precision than the index
-- would miss ancestor cells. For the Bench we always pick query_precision
-- coarser than the chosen index_precision, so this is fine; if you ever want
-- arbitrary query precisions you'd need to either store at level 10 only
-- (one cell per row, points-only — see geohash_candidates() in the
-- distortion_test setup for that pattern) or add an explicit ancestor walk.
-- ============================================================================

CREATE OR REPLACE FUNCTION cgeo_text_spatial_candidates(
    p_table_name      text,
    p_query_geom      geometry,
    p_query_precision int
) RETURNS SETOF int8
LANGUAGE plpgsql AS $$
DECLARE
    idx_table text := p_table_name || '_cgeo_index';
    xmin float8;
    ymin float8;
    xmax float8;
    ymax float8;
    pairs text[];
    n int;
    mins text[] := ARRAY[]::text[];
    maxs text[] := ARRAY[]::text[];
BEGIN
    xmin := ST_XMin(p_query_geom);
    ymin := ST_YMin(p_query_geom);
    xmax := ST_XMax(p_query_geom);
    ymax := ST_YMax(p_query_geom);

    pairs := c_geohash_l10_ranges_merged(xmin, ymin, xmax, ymax, p_query_precision);
    n := coalesce(array_length(pairs, 1), 0);
    IF n = 0 THEN
        RETURN;
    END IF;

    -- Flatten (min10, max10) pairs into two parallel arrays so the inner
    -- range scan is one BNL-batched join (mirrors the S2 helper).
    FOR i IN 1..(n/2) LOOP
        mins := mins || pairs[2*i - 1];
        maxs := maxs || pairs[2*i];
    END LOOP;

    RETURN QUERY EXECUTE format(
        'SELECT t.id FROM %I t '
        '  JOIN unnest($1::text[], $2::text[]) AS r(rmin, rmax) '
        '    ON t.geohash BETWEEN r.rmin AND r.rmax',
        idx_table
    ) USING mins, maxs;
END;
$$;

-- ============================================================================
-- create_cgeo_text_spatial_index('table', 'geom_col', 'pk_col', index_prec)
--
-- Creates the mapping table <table>_cgeo_index(id, geohash) with PK
-- (geohash ASC, id) so range scans stay inside contiguous tablet slices,
-- plus an INSERT/UPDATE trigger that auto-populates the mapping by
-- bbox-covering the row geometry at `index_prec` and right-padding to 10.
--
-- For Points the bbox cover is a single cell (degenerate bbox). For
-- LineStrings/Polygons it is the cells covering the geometry's bbox at the
-- chosen precision — looser than int64 c_geohash_cover_geometry's
-- line-rasterization, but bounded and apples-to-apples for a benchmark.
-- ============================================================================
CREATE OR REPLACE FUNCTION create_cgeo_text_spatial_index(
    p_table_name   text,
    p_geom_column  text DEFAULT 'geom',
    p_pk_column    text DEFAULT 'id',
    p_index_prec   int  DEFAULT 5
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    idx_table text := p_table_name || '_cgeo_index';
BEGIN
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I (
            id      int8 NOT NULL,
            geohash text NOT NULL,
            PRIMARY KEY (geohash ASC, id)
        )', idx_table
    );
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS %I ON %I (id)',
        idx_table || '_by_id', idx_table
    );
    EXECUTE format('DROP TRIGGER IF EXISTS trg_cgeo_%I ON %I',
                   p_table_name, p_table_name);
    EXECUTE format(
        'CREATE TRIGGER trg_cgeo_%I
         AFTER INSERT OR UPDATE ON %I
         FOR EACH ROW EXECUTE FUNCTION cgeo_text_auto_index(%L, %L, %L, %L)',
        p_table_name, p_table_name,
        p_geom_column, idx_table, p_pk_column, p_index_prec::text
    );
    RAISE NOTICE 'cgeo text index created: table=%, mapping=%, prec=%',
        p_table_name, idx_table, p_index_prec;
END;
$$;

-- ============================================================================
-- cgeo_text_auto_index — trigger function (the per-row analog of the bulk
-- INSERT in 04_setup_yb_cgeo.sh). Reads the geom column, computes its bbox
-- via ST_XMin/XMax/YMin/YMax, calls c_geohash_covering(bbox, index_prec),
-- right-pads each cell to 10 chars, inserts into the mapping table.
-- ============================================================================
CREATE OR REPLACE FUNCTION cgeo_text_auto_index() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    geom_col   text := TG_ARGV[0];
    idx_table  text := TG_ARGV[1];
    pk_col     text := TG_ARGV[2];
    idx_prec   int  := TG_ARGV[3]::int;
    pk_val     int8;
    g          geometry;
    cells      text[];
    pad_len    int;
    cell_padded text;
    sql        text;
BEGIN
    -- Pull pk + geom out of NEW via dynamic SQL (so the trigger is
    -- table-agnostic). Skip rows where geom IS NULL.
    EXECUTE format('SELECT ($1).%I::int8, ($1).%I::geometry', pk_col, geom_col)
        INTO pk_val, g USING NEW;
    IF g IS NULL THEN
        RETURN NEW;
    END IF;

    -- On UPDATE, clear the old mapping rows for this id first.
    IF TG_OP = 'UPDATE' THEN
        EXECUTE format('DELETE FROM %I WHERE id = $1', idx_table) USING pk_val;
    END IF;

    cells := c_geohash_covering(
        ST_XMin(g), ST_YMin(g), ST_XMax(g), ST_YMax(g), idx_prec);
    IF cells IS NULL OR array_length(cells, 1) IS NULL THEN
        RETURN NEW;
    END IF;

    sql := format(
        'INSERT INTO %I (id, geohash) VALUES ($1, $2) ON CONFLICT DO NOTHING',
        idx_table);
    FOR i IN 1..array_length(cells, 1) LOOP
        pad_len := 10 - length(cells[i]);
        IF pad_len > 0 THEN
            cell_padded := cells[i] || repeat('0', pad_len);
        ELSE
            cell_padded := cells[i];
        END IF;
        EXECUTE sql USING pk_val, cell_padded;
    END LOOP;

    RETURN NEW;
END;
$$;
