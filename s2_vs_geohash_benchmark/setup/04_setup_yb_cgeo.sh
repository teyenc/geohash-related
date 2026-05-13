#!/usr/bin/env bash
# ============================================================================
# 04_setup_yb_cgeo.sh
#
# Creates YB database `bench_cgeo`, installs c_geohash (the prefix-indexing
# extension under test, text-API only — provides its own `geometry` type and
# ST_* surface, no dependency on yb_geospatial_s2). Loads only the 344K POI
# rows and builds the c_geohash mapping table for POIs.
#
# Rivers are loaded by 03_setup_rivers.sh (along with bench_postgis /
# bench_dans / bench_s2), so this script must run BEFORE 03.
#
# Storage model (text API):
#   * <table>_cgeo_index(entry_id int8, geohash text NOT NULL,
#                        PRIMARY KEY (geohash ASC, entry_id))
#     `entry_id` matches the column name yb_geospatial_s2 uses for its
#     <table>_s2_index mapping, so the two engines have a unified schema.
#   * Cells are stored as canonical base-32 geohash strings right-padded to
#     10 chars. Index precision is per-table:
#       - my_mapdata (Points)           : level 10  (~1 m × 0.6 m, 1 cell/row)
#       - rivers     (LineStrings)      : level 5   (~5 km × 5 km, set up in 03)
#   * Query side issues `BETWEEN min10 AND max10` per (min10, max10) pair from
#     the adaptive c_geohash_cover_geometry. Constraint: query max_precision
#     ≤ index precision (see comments above cgeo_text_spatial_candidates in
#     src/postgres/yb-extensions/c_geohash/c_geohash--1.0.sql for why).
#
# This script intentionally mirrors 02_setup_yb_s2.sh so any latency delta
# between the two engines is attributable to the cell-encoding (S2 vs.
# geohash) and not to schema or load-pattern differences.
# ============================================================================
set -euo pipefail

YB_BIN=/net/dev-server-te-yenchou/share/code/yugabyte-db/build/latest/postgres/bin
ROOT=$(cd "$(dirname "$0")"/..; pwd)
DATA_PIPE="/net/dev-server-te-yenchou/share/code/geohash-related/geospatial_demo/data/19_mapData.pipe"
PSQL=( "$YB_BIN/ysqlsh" -h 127.0.0.1 -p 5433 -U yugabyte -v ON_ERROR_STOP=1 -X )

# ---- early-out if bench_cgeo is already fully loaded ------------------------
# Skip the destructive DROP DATABASE + reload (~60s) when bench_cgeo exists
# with:
#   * my_mapdata.count = 344688
#   * my_mapdata_cgeo_index populated
#   * my_mapdata_cgeo_index_by_entry_id secondary index present (used by the
#     auto-fill trigger's reverse lookup on UPDATE/DELETE)
# Any failure falls through to the destructive path below.
already_loaded() {
    local out
    out=$("$YB_BIN/ysqlsh" -h 127.0.0.1 -p 5433 -U yugabyte -d bench_cgeo -tA \
            -c "SELECT (SELECT count(*) FROM my_mapdata) || '|' ||
                       (SELECT (count(*) > 0)::int FROM my_mapdata_cgeo_index) || '|' ||
                       (SELECT count(*) FROM pg_class
                         WHERE relname='my_mapdata_cgeo_index_by_entry_id')" 2>/dev/null) || return 1
    [ "$out" = "344688|1|1" ]
}
if already_loaded; then
    echo "[yb-cgeo] bench_cgeo already loaded (my_mapdata=344688, cgeo mapping filled, secondary idx present) -- skipping rebuild."
    exit 0
fi

echo "[yb-cgeo] dropping + recreating bench_cgeo"
"${PSQL[@]}" -d yugabyte <<SQL
DROP DATABASE IF EXISTS bench_cgeo;
CREATE DATABASE bench_cgeo;
SQL

CGEO_PSQL=( "$YB_BIN/ysqlsh" -h 127.0.0.1 -p 5433 -U yugabyte -v ON_ERROR_STOP=1 -X -d bench_cgeo )

echo "[yb-cgeo] installing extension..."
# c_geohash is standalone: it registers its own geometry type, the
# ST_GeomFromText / ST_X / ST_Y / ST_MakeEnvelope surface this script uses
# below, AND the cgeo_text_spatial_candidates / create_cgeo_text_spatial_index /
# cgeo_text_auto_index helpers that the planner hook references and the
# benchmark relies on. Everything is now in the extension SQL — no separate
# helpers file load needed. (No yb_geospatial_s2 needed either, and the two
# cannot coexist because both would try to install the same `geometry` type.)
"${CGEO_PSQL[@]}" <<SQL
CREATE EXTENSION c_geohash;
SQL

echo "[yb-cgeo] creating my_mapdata schema (POIs at index_prec=10)..."
"${CGEO_PSQL[@]}" <<SQL
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

-- Points: index at level 10 (1 cell per row). Any query precision in
-- [1..10] is supported.
SELECT create_cgeo_text_spatial_index('my_mapdata', 'geom', 'md_pk', 10);

-- Disable the trigger during bulk load; rebuild the mapping table manually
-- afterwards to avoid per-row plpgsql trigger overhead during COPY / UPDATE.
ALTER TABLE my_mapdata DISABLE TRIGGER trg_cgeo_my_mapdata;
SQL

echo "[yb-cgeo] loading 344K POI rows..."
"${CGEO_PSQL[@]}" <<SQL
\\copy my_mapdata(md_pk, md_lat, md_lng, geo_hash10, md_name, md_address, md_city, md_province, md_country, md_postcode, md_phone, md_category, md_subcategory, md_mysource, md_tags, md_type) FROM '$DATA_PIPE' WITH (FORMAT csv, DELIMITER '|', HEADER true, ROWS_PER_TRANSACTION 5000)
SQL

echo "[yb-cgeo] building geometry column..."
"${CGEO_PSQL[@]}" <<SQL
UPDATE my_mapdata
   SET geom = ST_GeomFromText('POINT(' || md_lng || ' ' || md_lat || ')', 4326)
 WHERE md_lat IS NOT NULL AND md_lng IS NOT NULL;
SQL

echo "[yb-cgeo] building c_geohash mapping table for POIs (level 10)..."
# A Point at level 10 has exactly one cell. c_geohash_encode(lat, lon, 10)
# returns that 10-char string directly, no rpad needed.
"${CGEO_PSQL[@]}" <<SQL
ALTER TABLE my_mapdata ENABLE TRIGGER trg_cgeo_my_mapdata;

INSERT INTO my_mapdata_cgeo_index (entry_id, geohash)
SELECT md_pk, c_geohash_encode(ST_Y(geom), ST_X(geom), 10)
  FROM my_mapdata
 WHERE geom IS NOT NULL
ON CONFLICT DO NOTHING;
SQL

echo "[yb-cgeo] row counts (POIs only — rivers are loaded by 03_setup_rivers.sh):"
"${CGEO_PSQL[@]}" <<SQL
SELECT 'my_mapdata'             AS tbl, count(*) AS n FROM my_mapdata
UNION ALL
SELECT 'my_mapdata_cgeo_index',         count(*)      FROM my_mapdata_cgeo_index;
SQL
echo "[yb-cgeo] done."
