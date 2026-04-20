#!/usr/bin/env bash
# ============================================================================
# 00_setup_postgis.sh
#
# Initializes a fresh PostgreSQL 15 cluster on port 54321 with PostGIS 3.5
# enabled and loads the 344K-row POI dataset from Dan's demo.
#
# Idempotent: safe to re-run.  Writes its data directory under BENCH_ROOT.
# ============================================================================
set -euo pipefail

BENCH_ROOT=${BENCH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.."; pwd)}
PG_BIN=/usr/pgsql-15/bin
PG_DATA=$BENCH_ROOT/pg_data
PG_PORT=${PG_PORT:-54321}
PG_LOG=$BENCH_ROOT/results/pg_server.log
DATA_PIPE="/net/dev-server-te-yenchou/share/code/geospatial_v05/20 - sql/19_mapData.pipe"

mkdir -p "$BENCH_ROOT/results"

# ---- 0. clear any stale listener on the target port ----
# If a previous run left a postmaster alive (or the user wiped pg_data while
# the old postgres was still running), pg_ctl start would fail with
# "Address already in use".  Stop our own cluster gracefully first, and if
# something else still holds the port, kill whoever owns it.
"$PG_BIN/pg_ctl" -D "$PG_DATA" -m fast stop 2>/dev/null || true

# Returns the pid holding 127.0.0.1:$PG_PORT, or empty string if no one is.
# Tolerant of both "nothing listens on this port" and missing `ss` output.
port_holder_pid() {
  local line
  line=$(ss -tlnp 2>/dev/null | awk -v p=":$PG_PORT" '$4 ~ p"$" { print; exit }' ) || true
  [ -n "$line" ] || { echo ""; return 0; }
  echo "$line" | grep -oP 'pid=\K[0-9]+' | head -1 || true
}
pid=$(port_holder_pid)
if [ -n "${pid:-}" ]; then
  echo "[pg] clearing stale process on port $PG_PORT (pid=$pid)"
  kill -9 "$pid" 2>/dev/null || true
  sleep 2
fi
pid=$(port_holder_pid)
if [ -n "${pid:-}" ]; then
  echo "[pg] ERROR: port $PG_PORT is still bound by pid=$pid after cleanup attempt." >&2
  echo "      Stop that process or set PG_PORT=<other> and re-run." >&2
  exit 1
fi

# ---- 1. initdb (if a fresh data dir is needed) ----
if [ ! -f "$PG_DATA/PG_VERSION" ]; then
  echo "[pg] initdb -> $PG_DATA"
  "$PG_BIN/initdb" -D "$PG_DATA" --encoding=UTF8 --locale=C -U "$USER" > /dev/null
  # Loosen auth for local benchmark use
  sed -i "s|^#\?listen_addresses.*|listen_addresses = '127.0.0.1'|"          "$PG_DATA/postgresql.conf"
  sed -i "s|^#\?port .*|port = $PG_PORT|"                                    "$PG_DATA/postgresql.conf"
  sed -i "s|^#\?unix_socket_directories.*|unix_socket_directories = '/tmp'|" "$PG_DATA/postgresql.conf"
  sed -i "s|^#\?shared_buffers.*|shared_buffers = 256MB|"                    "$PG_DATA/postgresql.conf"
  sed -i "s|^#\?work_mem.*|work_mem = 64MB|"                                 "$PG_DATA/postgresql.conf"
  sed -i "s|^#\?fsync.*|fsync = off|"                                        "$PG_DATA/postgresql.conf"
  sed -i "s|^#\?synchronous_commit.*|synchronous_commit = off|"              "$PG_DATA/postgresql.conf"
fi

# ---- 2. start ----
echo "[pg] starting on port $PG_PORT"
"$PG_BIN/pg_ctl" -D "$PG_DATA" -l "$PG_LOG" -w start

# ---- 3. database + extension ----
PSQL=( "$PG_BIN/psql" -h 127.0.0.1 -p $PG_PORT -U "$USER" -v ON_ERROR_STOP=1 -X )

"${PSQL[@]}" -d postgres <<SQL
DROP DATABASE IF EXISTS bench_postgis;
CREATE DATABASE bench_postgis;
SQL

"${PSQL[@]}" -d bench_postgis <<SQL
CREATE EXTENSION postgis;

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
  geom           geometry(Point, 4326)
);
SQL

# ---- 4. copy data ----
echo "[pg] loading 344K rows..."
"${PSQL[@]}" -d bench_postgis <<SQL
\\copy my_mapdata(md_pk, md_lat, md_lng, geo_hash10, md_name, md_address, md_city, md_province, md_country, md_postcode, md_phone, md_category, md_subcategory, md_mysource, md_tags, md_type) FROM '$DATA_PIPE' WITH (FORMAT csv, DELIMITER '|', HEADER true)

UPDATE my_mapdata
   SET geom = ST_SetSRID(ST_MakePoint(md_lng::float8, md_lat::float8), 4326)
 WHERE md_lat IS NOT NULL AND md_lng IS NOT NULL;

CREATE INDEX ix_my_mapdata_geom_gist ON my_mapdata USING GIST (geom);
ANALYZE my_mapdata;
SQL

echo ""
echo "[pg] ready. Connect with:"
echo "    $PG_BIN/psql -h 127.0.0.1 -p $PG_PORT -d bench_postgis"
"${PSQL[@]}" -d bench_postgis -c "SELECT count(*) AS rows, pg_size_pretty(pg_relation_size('ix_my_mapdata_geom_gist')) AS gist_idx_size FROM my_mapdata;"
