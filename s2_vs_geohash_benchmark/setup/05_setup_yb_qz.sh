#!/usr/bin/env bash
# ============================================================================
# 05_setup_yb_qz.sh
#
# Creates YB database `bench_qz`, installs c_quadtree_z (the 4-ary tree +
# Z-order extension under test) alongside c_geohash (which c_quadtree_z
# borrows the geometry type + ST_* surface from — c_quadtree_z itself only
# ships two C functions and no PG type machinery).
#
# Loads 344K POI rows from my_mapdata, then builds my_mapdata_qz_index using
# c_qz_encode_str(lon, lat, 17). Bulk-fill, no trigger.
#
# Storage model (matches the gh and s2 patterns):
#   * my_mapdata_qz_index(entry_id int8, qz_path text NOT NULL,
#                         PRIMARY KEY (qz_path ASC, entry_id))
#   * `entry_id` matches the unified column name used by the gh / s2
#     mapping tables.
#   * Leaf level 18: cells are 0.00137° lon × 0.000687° lat
#     ≈ 153 m × 76 m at the equator. Cell area ~11,700 m², SMALLER
#     than S2-16's ~20,164 m² (~142m square). Picking the smaller-cell
#     side of the S2-16 size flips the cell-size confound: any qz
#     advantage in cluster count is now PURELY the Z-order-curve effect
#     vs S2's Hilbert curve (Faloutsos paper predicts qz/s2 ~ 1.85,
#     i.e. S2 emits ~43-48% fewer cells for matched-cell-size queries).
#
# Why c_geohash is also installed here:
#   c_quadtree_z does NOT register its own `geometry` type — it just uses
#   whichever one is in the DB. Of the two extensions that provide one,
#   c_geohash is the lighter pick (no S2 dependency, no S2 planner hook
#   that could contaminate measurements). The c_geohash planner hook only
#   triggers on `<table>_cgeo_index` mapping tables; ours is named
#   `_qz_index`, so it's invisible to the hook and our QZ queries run as
#   plain SQL.
#
# Rivers are intentionally NOT loaded here — the latency / cell-count
# sweeps only use my_mapdata (POIs).
# ============================================================================
set -euo pipefail

YB_BIN=/net/dev-server-te-yenchou/share/code/yugabyte-db/build/latest/postgres/bin
DATA_PIPE="/net/dev-server-te-yenchou/share/code/geohash-related/geospatial_demo/data/19_mapData.pipe"

PSQL=( "$YB_BIN/ysqlsh" -h 127.0.0.1 -p 5433 -U yugabyte -v ON_ERROR_STOP=1 -X )

# ---- early-out if bench_qz is already fully loaded --------------------------
# Skip the destructive DROP DATABASE + reload when bench_qz exists with:
#   * my_mapdata.count = 344688
#   * my_mapdata_qz_index populated
#   * my_mapdata_qz_index_by_entry_id secondary index present
#   * qz_text_spatial_candidates helper installed
already_loaded() {
    local out
    out=$("$YB_BIN/ysqlsh" -h 127.0.0.1 -p 5433 -U yugabyte -d bench_qz -tA \
            -c "SELECT (SELECT count(*) FROM my_mapdata) || '|' ||
                       (SELECT (count(*) > 0)::int FROM my_mapdata_qz_index) || '|' ||
                       (SELECT count(*) FROM pg_class
                         WHERE relname='my_mapdata_qz_index_by_entry_id') || '|' ||
                       (SELECT count(*) FROM pg_proc
                         WHERE proname='qz_text_spatial_candidates')" 2>/dev/null) || return 1
    [ "$out" = "344688|1|1|1" ]
}
if already_loaded; then
    echo "[yb-qz] bench_qz already loaded (my_mapdata=344688, qz mapping filled, secondary idx + helper present) -- skipping rebuild."
    exit 0
fi

echo "[yb-qz] dropping + recreating bench_qz"
"${PSQL[@]}" -d yugabyte <<SQL
DROP DATABASE IF EXISTS bench_qz;
CREATE DATABASE bench_qz;
SQL

QZ_PSQL=( "$YB_BIN/ysqlsh" -h 127.0.0.1 -p 5433 -U yugabyte -v ON_ERROR_STOP=1 -X -d bench_qz )

echo "[yb-qz] installing extensions and building schema..."
"${QZ_PSQL[@]}" <<SQL
-- c_geohash provides the geometry type + ST_* surface that c_quadtree_z
-- piggy-backs on. The c_geohash planner hook only intercepts queries
-- against <table>_cgeo_index, so our _qz_index workload is unaffected.
CREATE EXTENSION c_geohash;
CREATE EXTENSION c_quadtree_z;

CREATE TABLE my_mapdata (
  md_pk          BIGINT PRIMARY KEY,
  md_lat         TEXT,
  md_lng         TEXT,
  geo_hash10     TEXT,
  md_name        TEXT,
  md_address     TEXT,
  md_city        TEXT,
  md_province    TEXT,
  md_country     TEXT,
  md_postcode    TEXT,
  md_phone       TEXT,
  md_category    TEXT,
  md_subcategory TEXT,
  md_mysource    TEXT,
  md_tags        TEXT,
  md_type        TEXT,
  geom           geometry
);

-- Mapping table mirrors the gh / s2 schemas: unified `entry_id` column.
CREATE TABLE my_mapdata_qz_index (
    entry_id int8 NOT NULL,
    qz_path  text NOT NULL,
    PRIMARY KEY (qz_path ASC, entry_id)
);
CREATE INDEX my_mapdata_qz_index_by_entry_id
    ON my_mapdata_qz_index (entry_id);
SQL

echo "[yb-qz] loading 344K POI rows..."
"${QZ_PSQL[@]}" <<SQL
\\copy my_mapdata(md_pk, md_lat, md_lng, geo_hash10, md_name, md_address, md_city, md_province, md_country, md_postcode, md_phone, md_category, md_subcategory, md_mysource, md_tags, md_type) FROM '$DATA_PIPE' WITH (FORMAT csv, DELIMITER '|', HEADER true, ROWS_PER_TRANSACTION 5000)
SQL

echo "[yb-qz] building geometry column..."
"${QZ_PSQL[@]}" <<SQL
UPDATE my_mapdata
   SET geom = ST_GeomFromText('POINT(' || md_lng || ' ' || md_lat || ')', 4326)
 WHERE md_lat IS NOT NULL AND md_lng IS NOT NULL;
SQL

echo "[yb-qz] bulk-filling my_mapdata_qz_index at level 18 (~153 m × 76 m at equator)..."
"${QZ_PSQL[@]}" <<SQL
INSERT INTO my_mapdata_qz_index (entry_id, qz_path)
SELECT md_pk, c_qz_encode_str(ST_X(geom), ST_Y(geom), 18)
  FROM my_mapdata
 WHERE geom IS NOT NULL
ON CONFLICT DO NOTHING;
SQL

echo "[yb-qz] installing qz_text_spatial_candidates helper..."
# Parameterized adaptive cover. Same shape as cgeo_text_spatial_candidates
# (the gh side) and spatial_candidates_v2 (the s2 side): build the cover
# as (min_path, max_path) text pairs, range-scan the mapping table for
# each pair, AND walk ancestors. UNION ALL.
#
# Min level fixed at 5: that gives ~11° × 5.6° coarse cells, matching
# gh's min_precision=2 in coarse cell area. Storage width: 30 chars
# (qz path length), base-4 alphabet '0'..'3'.
#
# !! IMPORTANT — DO NOT REMOVE THE ANCESTOR WALK !!
# ----------------------------------------------------------------------------
# Mirrors the descendants + ancestors structure of s2's spatial_candidates_v2
# and cgeo_text_spatial_candidates. Without ancestors the per-cell work would
# be ~half what s2 pays, biasing the qz/s2 latency comparison and confounding
# the Hilbert-vs-Z-order isolation experiment. For uniform-leaf-storage
# tables (qz_path computed at level 18 for points) the ancestor ARRAY
# lookups return zero rows, but the work to look them up is still paid —
# which is the cost we want measured. See the long comment above
# cgeo_text_spatial_candidates in
# src/postgres/yb-extensions/c_geohash/c_geohash--1.0.sql for the full
# rationale.
"${QZ_PSQL[@]}" <<'SQL'
CREATE OR REPLACE FUNCTION qz_text_spatial_candidates(
    p_table_name      text,
    p_query_geom      geometry,
    p_query_max_level int
) RETURNS SETOF int8
LANGUAGE plpgsql AS $$
DECLARE
    idx_table text := p_table_name || '_qz_index';
    pairs text[];
    n int;
    min_pad text;
    max_pad text;
    cell_level int;
    cell_prefix text;
    ancestors text[];
    j int;
    la int;
BEGIN
    pairs := c_qz_cover_geometry_str(p_query_geom, 5, p_query_max_level,
                                     1000000);
    n := coalesce(array_length(pairs, 1), 0) / 2;

    FOR i IN 1..n LOOP
        min_pad := pairs[2 * i - 1];
        max_pad := pairs[2 * i];

        -- Recover the cover cell's level from the (min30, max30) pair.
        -- The strings share a common prefix equal to the cell encoding;
        -- the first differing char position is the level.
        cell_level := 30;
        FOR j IN 1..30 LOOP
            IF substring(min_pad FROM j FOR 1) <> substring(max_pad FROM j FOR 1) THEN
                cell_level := j - 1;
                EXIT;
            END IF;
        END LOOP;
        cell_prefix := substring(min_pad FROM 1 FOR cell_level);

        -- Ancestors: coarser-level cells this cover cell sits inside,
        -- right-padded with '0' to 30 chars (the storage column width).
        -- la=1 is the coarsest qz level (4 cells covering Earth).
        ancestors := ARRAY[]::text[];
        IF cell_level > 1 THEN
            FOR la IN 1..(cell_level - 1) LOOP
                ancestors := ancestors ||
                             (substring(cell_prefix FROM 1 FOR la) ||
                              repeat('0', 30 - la));
            END LOOP;
        END IF;

        RETURN QUERY EXECUTE format(
            'SELECT entry_id FROM %I WHERE qz_path BETWEEN $1 AND $2 '
            'UNION ALL '
            'SELECT entry_id FROM %I WHERE qz_path = ANY($3)',
            idx_table, idx_table)
        USING min_pad, max_pad, ancestors;
    END LOOP;
END;
$$;
SQL

echo "[yb-qz] row counts:"
"${QZ_PSQL[@]}" <<SQL
SELECT 'my_mapdata'              AS tbl, count(*) AS n FROM my_mapdata
UNION ALL
SELECT 'my_mapdata_qz_index',           count(*)      FROM my_mapdata_qz_index;
SQL
echo "[yb-qz] done."
