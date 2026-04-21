#!/usr/bin/env bash
# ==============================================================================
# 03_setup_rivers.sh
#
# Loads 100,000 synthetic rivers (LineStrings) into all three benchmark DBs:
#   - bench_postgis : rivers(id, name, geom geometry(LineString, 4326)) + GiST
#   - bench_dans    : rivers(id, name, geom geometry)           -- Dan's (lon[],lat[])
#                                                               -- NO INDEX (by design;
#                                                               -- geohash-per-row can't
#                                                               -- cover a line)
#   - bench_s2      : rivers(id, name, geom geometry) + S2 auto-index trigger
# ==============================================================================
set -euo pipefail

ROOT=$(cd "$(dirname "$0")"/..; pwd)
DATA="$ROOT/data/rivers.csv"
YB_BIN=/net/dev-server-te-yenchou/share/code/yugabyte-db/build/latest/postgres/bin
PG_BIN=/usr/pgsql-15/bin

if [ ! -s "$DATA" ]; then
  echo "[rivers] generating $DATA"
  mkdir -p "$(dirname "$DATA")"
  python3 "$ROOT/setup/gen_rivers.py" > "$DATA"
fi
echo "[rivers] dataset: $(wc -l < "$DATA") lines"

# ---------- PostGIS ----------
echo ""
echo "[rivers] loading into bench_postgis ..."
$PG_BIN/psql -h 127.0.0.1 -p 54321 -d bench_postgis -v ON_ERROR_STOP=1 -qX <<SQL
DROP TABLE IF EXISTS rivers CASCADE;
CREATE TABLE rivers (
  id        BIGINT PRIMARY KEY,
  name      TEXT,
  wkt       TEXT,
  lon_array TEXT,
  lat_array TEXT,
  geom      geometry(LineString, 4326)
);
\copy rivers(id, name, wkt, lon_array, lat_array) FROM '$DATA' WITH (FORMAT csv, DELIMITER '|', HEADER true)
UPDATE rivers SET geom = ST_GeomFromText(wkt, 4326);
CREATE INDEX ix_rivers_geom_gist ON rivers USING GIST (geom);
ANALYZE rivers;
SELECT 'rivers' AS tbl, count(*) AS n, pg_size_pretty(pg_relation_size('ix_rivers_geom_gist')) AS gist FROM rivers;
SQL

# ---------- Dan's ----------
echo ""
echo "[rivers] loading into bench_dans ..."
$YB_BIN/ysqlsh -h 127.0.0.1 -p 5433 -U yugabyte -d bench_dans -v ON_ERROR_STOP=1 -qX <<SQL
DROP TABLE IF EXISTS rivers CASCADE;
CREATE TABLE rivers (
  id        BIGINT PRIMARY KEY,
  name      TEXT,
  wkt       TEXT,
  lon_array TEXT,
  lat_array TEXT,
  geom      geometry    -- Dan's custom composite type: (lon double[], lat double[])
);
\copy rivers(id, name, wkt, lon_array, lat_array) FROM '$DATA' WITH (FORMAT csv, DELIMITER '|', HEADER true)
UPDATE rivers
   SET geom = (
     ROW(lon_array::double precision[], lat_array::double precision[])::geometry
   );
-- Deliberately NO index: Dan's schema only supports one geohash per row, which
-- cannot represent a multi-cell line.  Queries will seq-scan.
SELECT 'rivers' AS tbl, count(*) AS n FROM rivers;
SQL

# ---------- S2 ----------
echo ""
echo "[rivers] loading into bench_s2 ..."
$YB_BIN/ysqlsh -h 127.0.0.1 -p 5433 -U yugabyte -d bench_s2 -v ON_ERROR_STOP=1 -qX <<SQL
DROP TABLE IF EXISTS rivers CASCADE;
CREATE TABLE rivers (
  id   BIGINT PRIMARY KEY,
  name TEXT,
  wkt  TEXT,
  geom geometry
);

SELECT create_spatial_index('rivers', 'geom', 'id');
ALTER TABLE rivers DISABLE TRIGGER trg_s2_rivers;

\copy rivers(id, name, wkt) FROM PROGRAM 'awk -F"|" ''NR > 1 {print \$1 "|" \$2 "|" \$3}'' $DATA' WITH (FORMAT csv, DELIMITER '|')

UPDATE rivers SET geom = ST_GeomFromText(wkt, 4326);

-- Bulk-populate the S2 mapping table (same as POI setup).
INSERT INTO rivers_s2_index (id, s2_cell)
SELECT id, unnest(ST_S2Covering(geom, 10, 20))
  FROM rivers
 WHERE geom IS NOT NULL
ON CONFLICT DO NOTHING;

ALTER TABLE rivers ENABLE TRIGGER trg_s2_rivers;

SELECT 'rivers'          AS tbl, count(*) AS n FROM rivers
UNION ALL
SELECT 'rivers_s2_index',         count(*)      FROM rivers_s2_index;
SQL
