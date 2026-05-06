#!/usr/bin/env bash
# ============================================================================
# 04_setup_yb_cgeo.sh
#
# Creates YB database `bench_cgeo`, installs yb_geospatial_s2 (for the
# `geometry` type only — bench_cgeo uses the SAME on-disk EWKB layout as
# bench_s2) and c_geohash (the prefix-indexing extension under test, now
# text-API only). Loads 344K POI rows + 100K rivers and builds the c_geohash
# mapping tables in bulk.
#
# Storage model (text API):
#   * <table>_cgeo_index(id int8, geohash text NOT NULL,
#                        PRIMARY KEY (geohash ASC, id))
#   * Cells are stored as canonical base-32 geohash strings right-padded to
#     10 chars. Index precision is per-table:
#       - my_mapdata (Points)           : level 10  (~1 m × 0.6 m, 1 cell/row)
#       - rivers     (LineStrings)      : level 5   (~5 km × 5 km, ≤ ~225 cells
#                                                    per ~75 km river bbox)
#   * Query side issues `BETWEEN min10 AND max10` per (min10, max10) pair from
#     c_geohash_l10_ranges_merged. Constraint: query precision ≤ index
#     precision (see cgeo_text_helpers.sql for why).
#
# This script intentionally mirrors 02_setup_yb_s2.sh and the bench_s2 block
# of 03_setup_rivers.sh as closely as possible, so any latency delta between
# the two engines is attributable to the cell-encoding (S2 vs. geohash) and
# not to schema or load-pattern differences.
# ============================================================================
set -euo pipefail

YB_BIN=/net/dev-server-te-yenchou/share/code/yugabyte-db/build/latest/postgres/bin
ROOT=$(cd "$(dirname "$0")"/..; pwd)
DATA_PIPE="/net/dev-server-te-yenchou/share/code/geohash-related/geospatial_demo/data/19_mapData.pipe"
RIVERS_DATA="$ROOT/data/rivers.csv"
HELPERS_SQL="$ROOT/setup/cgeo_text_helpers.sql"

PSQL=( "$YB_BIN/ysqlsh" -h 127.0.0.1 -p 5433 -U yugabyte -v ON_ERROR_STOP=1 -X )

echo "[yb-cgeo] dropping + recreating bench_cgeo"
"${PSQL[@]}" -d yugabyte <<SQL
DROP DATABASE IF EXISTS bench_cgeo;
CREATE DATABASE bench_cgeo;
SQL

CGEO_PSQL=( "$YB_BIN/ysqlsh" -h 127.0.0.1 -p 5433 -U yugabyte -v ON_ERROR_STOP=1 -X -d bench_cgeo )

echo "[yb-cgeo] installing extensions and helpers..."
"${CGEO_PSQL[@]}" <<SQL
-- yb_geospatial_s2 supplies the geometry type + ST_GeomFromText etc.
-- (YB has no PostGIS, so we share the type with bench_s2.) c_geohash
-- itself no longer depends on it.
CREATE EXTENSION yb_geospatial_s2;
CREATE EXTENSION c_geohash;
SQL
"${CGEO_PSQL[@]}" -f "$HELPERS_SQL"

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
# A Point's bbox-cover at level 10 is exactly one cell, so this is one row
# per POI. The level-10 string is already 10 chars; rpad is a no-op but
# kept explicit for parity with the rivers path below.
"${CGEO_PSQL[@]}" <<SQL
ALTER TABLE my_mapdata ENABLE TRIGGER trg_cgeo_my_mapdata;

INSERT INTO my_mapdata_cgeo_index (id, geohash)
SELECT md_pk,
       rpad((c_geohash_covering(ST_XMin(geom), ST_YMin(geom),
                                ST_XMax(geom), ST_YMax(geom), 10))[1], 10, '0')
  FROM my_mapdata
 WHERE geom IS NOT NULL
ON CONFLICT DO NOTHING;
SQL

# ---------- Rivers ----------
if [ ! -s "$RIVERS_DATA" ]; then
  echo "[yb-cgeo] generating $RIVERS_DATA"
  mkdir -p "$(dirname "$RIVERS_DATA")"
  python3 "$ROOT/setup/gen_rivers.py" > "$RIVERS_DATA"
fi

echo "[yb-cgeo] loading 100K rivers (index_prec=5)..."
"${CGEO_PSQL[@]}" <<SQL
DROP TABLE IF EXISTS rivers CASCADE;
CREATE TABLE rivers (
  id   BIGINT PRIMARY KEY,
  name TEXT,
  wkt  TEXT,
  geom geometry
);

-- Rivers: index at level 5 (~5 km cells). A 75 km river bbox fans out to
-- O((75/5)^2) ≈ 225 cells worst case; in practice rivers cluster near the
-- diagonal so it averages much less.
SELECT create_cgeo_text_spatial_index('rivers', 'geom', 'id', 5);
ALTER TABLE rivers DISABLE TRIGGER trg_cgeo_rivers;

\\copy rivers(id, name, wkt) FROM PROGRAM 'awk -F"|" ''NR > 1 {print \$1 "|" \$2 "|" \$3}'' $RIVERS_DATA' WITH (FORMAT csv, DELIMITER '|')

UPDATE rivers SET geom = ST_GeomFromText(wkt, 4326);

INSERT INTO rivers_cgeo_index (id, geohash)
SELECT r.id, rpad(c.cell, 10, '0')
  FROM rivers r,
       LATERAL unnest(c_geohash_covering(
         ST_XMin(r.geom), ST_YMin(r.geom),
         ST_XMax(r.geom), ST_YMax(r.geom), 5)) AS c(cell)
 WHERE r.geom IS NOT NULL
ON CONFLICT DO NOTHING;

ALTER TABLE rivers ENABLE TRIGGER trg_cgeo_rivers;
SQL

echo "[yb-cgeo] row counts:"
"${CGEO_PSQL[@]}" <<SQL
SELECT 'my_mapdata'             AS tbl, count(*) AS n FROM my_mapdata
UNION ALL
SELECT 'my_mapdata_cgeo_index',         count(*)      FROM my_mapdata_cgeo_index
UNION ALL
SELECT 'rivers',                        count(*)      FROM rivers
UNION ALL
SELECT 'rivers_cgeo_index',             count(*)      FROM rivers_cgeo_index;
SQL
echo "[yb-cgeo] done."
