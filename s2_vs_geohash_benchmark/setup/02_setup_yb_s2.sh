#!/usr/bin/env bash
# ============================================================================
# 02_setup_yb_s2.sh
#
# Creates YB database `bench_s2`, installs yb_geospatial_s2 extension, loads
# 344K rows.  We disable the trigger during COPY and rebuild the S2 mapping
# table in one bulk step afterwards (so we don't pay per-row SPI overhead).
# ============================================================================
set -euo pipefail

YB_BIN=/net/dev-server-te-yenchou/share/code/yugabyte-db/build/latest/postgres/bin
DATA_PIPE="/net/dev-server-te-yenchou/share/code/geospatial_v05/20 - sql/19_mapData.pipe"

PSQL=( "$YB_BIN/ysqlsh" -h 127.0.0.1 -p 5433 -U yugabyte -v ON_ERROR_STOP=1 -X )

# ---- early-out if bench_s2 is already fully loaded --------------------------
# Skip the destructive DROP DATABASE + reload (~60s + ~30s S2 mapping fill)
# when bench_s2 exists with:
#   * my_mapdata.count = 344688
#   * my_mapdata_s2_index populated
#   * my_mapdata_s2_index_by_entry_id secondary index present (used by the
#     auto-fill trigger's reverse lookup on UPDATE/DELETE)
#   * spatial_candidates_v2 helper installed
# Any failure falls through to the destructive path below.
already_loaded() {
    local out
    out=$("$YB_BIN/ysqlsh" -h 127.0.0.1 -p 5433 -U yugabyte -d bench_s2 -tA \
            -c "SELECT (SELECT count(*) FROM my_mapdata) || '|' ||
                       (SELECT (count(*) > 0)::int FROM my_mapdata_s2_index) || '|' ||
                       (SELECT count(*) FROM pg_class
                         WHERE relname='my_mapdata_s2_index_by_entry_id') || '|' ||
                       (SELECT count(*) FROM pg_proc
                         WHERE proname='spatial_candidates_v2')" 2>/dev/null) || return 1
    [ "$out" = "344688|1|1|1" ]
}
if already_loaded; then
    echo "[yb-s2] bench_s2 already loaded (my_mapdata=344688, s2 mapping filled, secondary idx + v2 helper present) -- skipping rebuild."
    exit 0
fi

echo "[yb-s2] dropping + recreating bench_s2"
"${PSQL[@]}" -d yugabyte <<SQL
DROP DATABASE IF EXISTS bench_s2;
CREATE DATABASE bench_s2;
SQL

S2_PSQL=( "$YB_BIN/ysqlsh" -h 127.0.0.1 -p 5433 -U yugabyte -v ON_ERROR_STOP=1 -X -d bench_s2 )

echo "[yb-s2] installing yb_geospatial_s2 extension and building schema..."
"${S2_PSQL[@]}" <<SQL
CREATE EXTENSION yb_geospatial_s2;

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

-- Creates my_mapdata_s2_index (mapping table) + trigger trg_s2_my_mapdata
SELECT create_spatial_index('my_mapdata', 'geom', 'md_pk');

-- Disable the trigger during bulk load; we rebuild the mapping table manually
-- afterwards to avoid per-row SPI overhead during COPY / UPDATE.
ALTER TABLE my_mapdata DISABLE TRIGGER trg_s2_my_mapdata;
SQL

echo "[yb-s2] loading 344K rows..."
"${S2_PSQL[@]}" <<SQL
\\copy my_mapdata(md_pk, md_lat, md_lng, geo_hash10, md_name, md_address, md_city, md_province, md_country, md_postcode, md_phone, md_category, md_subcategory, md_mysource, md_tags, md_type) FROM '$DATA_PIPE' WITH (FORMAT csv, DELIMITER '|', HEADER true, ROWS_PER_TRANSACTION 5000)
SQL

echo "[yb-s2] building geometry column..."
"${S2_PSQL[@]}" <<SQL
UPDATE my_mapdata
   SET geom = ST_GeomFromText('POINT(' || md_lng || ' ' || md_lat || ')', 4326)
 WHERE md_lat IS NOT NULL AND md_lng IS NOT NULL;
SQL

echo "[yb-s2] building S2 mapping table in bulk (faster than trigger)..."
# Use ST_S2Covering on every row once, unnest into the mapping table.
"${S2_PSQL[@]}" <<SQL
ALTER TABLE my_mapdata ENABLE TRIGGER trg_s2_my_mapdata;

INSERT INTO my_mapdata_s2_index (entry_id, s2_cell)
SELECT md_pk, unnest(ST_S2Covering(geom, 10, 20))
  FROM my_mapdata
 WHERE geom IS NOT NULL
ON CONFLICT DO NOTHING;
SQL

echo "[yb-s2] installing spatial_candidates_v2 (parameterized cover)..."
# Same descendants + ancestors algorithm as the built-in spatial_candidates,
# but takes (min_level, max_level, max_cells) so the distortion sweep can
# pin the cover to the same levels c_geohash uses (min=10, max=16, 1M cells).
"${S2_PSQL[@]}" <<'SQL'
CREATE OR REPLACE FUNCTION spatial_candidates_v2(
    p_table_name text,
    p_query_geom geometry,
    p_min_level  int,
    p_max_level  int,
    p_max_cells  int
) RETURNS SETOF int8
LANGUAGE plpgsql AS $fn$
DECLARE
    idx_table   text := p_table_name || '_s2_index';
    query_cells int8[];
    cell        int8;
    range_min   int8;
    range_max   int8;
    ancestors   int8[];
    cur         int8;
    lsb         int8;
    new_lsb     int8;
    stop_lsb    int8 := 1::int8 << (2 * (30 - 4));  -- stop at level 4
BEGIN
    query_cells := ST_S2Covering(p_query_geom, p_min_level,
                                 p_max_level, p_max_cells);
    FOR i IN 1..coalesce(array_length(query_cells, 1), 0) LOOP
        cell      := query_cells[i];
        range_min := cell - ((cell & (-cell)) - 1);
        range_max := cell + ((cell & (-cell)) - 1);
        ancestors := ARRAY[]::int8[];
        cur := cell;
        LOOP
            lsb := cur & (-cur);
            EXIT WHEN lsb >= stop_lsb;
            new_lsb := lsb << 2;
            cur := (cur & (-new_lsb)) | new_lsb;
            ancestors := ancestors || cur;
        END LOOP;
        RETURN QUERY EXECUTE format(
            'SELECT entry_id FROM %I WHERE s2_cell BETWEEN $1 AND $2 '
            'UNION ALL '
            'SELECT entry_id FROM %I WHERE s2_cell = ANY($3)',
            idx_table, idx_table)
        USING range_min, range_max, ancestors;
    END LOOP;
END;
$fn$;
SQL

"${S2_PSQL[@]}" <<SQL
SELECT 'my_mapdata'         AS tbl, count(*) AS rows FROM my_mapdata
UNION ALL
SELECT 'my_mapdata_s2_index',         count(*)       FROM my_mapdata_s2_index;
SQL
echo "[yb-s2] done."
