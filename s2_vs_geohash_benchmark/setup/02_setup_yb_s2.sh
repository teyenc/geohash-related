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

INSERT INTO my_mapdata_s2_index (id, s2_cell)
SELECT md_pk, unnest(ST_S2Covering(geom, 10, 20))
  FROM my_mapdata
 WHERE geom IS NOT NULL
ON CONFLICT DO NOTHING;
SQL

"${S2_PSQL[@]}" <<SQL
SELECT 'my_mapdata'         AS tbl, count(*) AS rows FROM my_mapdata
UNION ALL
SELECT 'my_mapdata_s2_index',         count(*)       FROM my_mapdata_s2_index;
SQL
echo "[yb-s2] done."
