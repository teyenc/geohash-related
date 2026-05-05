#!/usr/bin/env bash
# ============================================================================
# 04_setup_yb_cgeo.sh
#
# Creates YB database `bench_cgeo`, installs both yb_geospatial_s2 (for the
# `geometry` type only — bench_cgeo uses the SAME on-disk EWKB layout as
# bench_s2) and c_geohash (the prefix-indexing extension under test). Loads
# 344K POI rows + 100K rivers and builds the c_geohash mapping tables in
# bulk.
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

PSQL=( "$YB_BIN/ysqlsh" -h 127.0.0.1 -p 5433 -U yugabyte -v ON_ERROR_STOP=1 -X )

echo "[yb-cgeo] dropping + recreating bench_cgeo"
"${PSQL[@]}" -d yugabyte <<SQL
DROP DATABASE IF EXISTS bench_cgeo;
CREATE DATABASE bench_cgeo;
SQL

CGEO_PSQL=( "$YB_BIN/ysqlsh" -h 127.0.0.1 -p 5433 -U yugabyte -v ON_ERROR_STOP=1 -X -d bench_cgeo )

echo "[yb-cgeo] installing extensions and building schema..."
"${CGEO_PSQL[@]}" <<SQL
-- yb_geospatial_s2 supplies the geometry type + ST_GeomFromText etc.
-- (YB has no PostGIS, so we share the type with bench_s2.)
CREATE EXTENSION yb_geospatial_s2;
CREATE EXTENSION c_geohash;

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

-- Creates my_mapdata_cgeo_index (mapping table) + trigger trg_cgeo_my_mapdata.
SELECT create_cgeo_spatial_index('my_mapdata', 'geom', 'md_pk');

-- Disable the trigger during bulk load; rebuild the mapping table manually
-- afterwards to avoid per-row SPI overhead during COPY / UPDATE.
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

echo "[yb-cgeo] building c_geohash mapping table in bulk..."
"${CGEO_PSQL[@]}" <<SQL
ALTER TABLE my_mapdata ENABLE TRIGGER trg_cgeo_my_mapdata;

INSERT INTO my_mapdata_cgeo_index (id, c_geo_cell)
SELECT md_pk, unnest(c_geohash_cover_geometry(geom, 4, 10))
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

echo "[yb-cgeo] loading 100K rivers..."
"${CGEO_PSQL[@]}" <<SQL
DROP TABLE IF EXISTS rivers CASCADE;
CREATE TABLE rivers (
  id   BIGINT PRIMARY KEY,
  name TEXT,
  wkt  TEXT,
  geom geometry
);

SELECT create_cgeo_spatial_index('rivers', 'geom', 'id');
ALTER TABLE rivers DISABLE TRIGGER trg_cgeo_rivers;

\\copy rivers(id, name, wkt) FROM PROGRAM 'awk -F"|" ''NR > 1 {print \$1 "|" \$2 "|" \$3}'' $RIVERS_DATA' WITH (FORMAT csv, DELIMITER '|')

UPDATE rivers SET geom = ST_GeomFromText(wkt, 4326);

-- Bulk-populate the c_geohash mapping table (one cover per row).
INSERT INTO rivers_cgeo_index (id, c_geo_cell)
SELECT id, unnest(c_geohash_cover_geometry(geom, 4, 10))
  FROM rivers
 WHERE geom IS NOT NULL
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
