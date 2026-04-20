#!/usr/bin/env bash
# ============================================================================
# run_benchmark.sh
#
# Runs Q1/Q2/Q3 on PostGIS, Dan's, and yb_geospatial_s2, 6x each (discard
# first warmup, take median of last 5).  Writes results/benchmark.json and
# prints a markdown summary table.
# ============================================================================
set -euo pipefail

ROOT=$(cd "$(dirname "$0")"; pwd)
RESULTS=$ROOT/results
mkdir -p "$RESULTS"

YB_BIN=/net/dev-server-te-yenchou/share/code/yugabyte-db/build/latest/postgres/bin
PG_BIN=/usr/pgsql-15/bin

psql_yb()  { $YB_BIN/ysqlsh -h 127.0.0.1 -p 5433 -U yugabyte -d "$1" -qAtX -c "$2"; }
psql_pg()  { $PG_BIN/psql   -h 127.0.0.1 -p 54321 -d "$1" -qAtX -c "$2"; }

ITERS=6   # 1 warmup + 5 measured
WARMUP=1

# Strip the EXPLAIN wrapper so we can \timing repeatedly
strip_explain() {
  sed -E 's|^EXPLAIN \(.*\)$|-- EXPLAIN stripped --|' "$1"
}

run_query() {
  local engine=$1 db=$2 sqlfile=$3
  local stripped="$RESULTS/_q.sql"
  strip_explain "$sqlfile" > "$stripped"

  local times=()
  for i in $(seq 1 $ITERS); do
    local t
    if [ "$engine" = "pg" ]; then
      t=$($PG_BIN/psql -h 127.0.0.1 -p 54321 -d "$db" -qAtX \
          -c "\timing on" -f "$stripped" 2>&1 \
          | awk '/^Time:/ {t=$2} END{print t}')
    else
      t=$($YB_BIN/ysqlsh -h 127.0.0.1 -p 5433 -U yugabyte -d "$db" -qAtX \
          -c "\timing on" -f "$stripped" 2>&1 \
          | awk '/^Time:/ {t=$2} END{print t}')
    fi
    times+=("$t")
  done
  # Drop warmup, compute median of rest
  local measured=("${times[@]:$WARMUP}")
  printf '%s\n' "${measured[@]}" | sort -n | awk 'NR==int((NR+1)/2){m=$1} END{print m}'
}

# ---- Correctness: hit counts (ignoring order) ----
pg_hits_q1=$(psql_pg bench_postgis "SELECT count(*) FROM my_mapdata WHERE ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography, 1000, true);")
pg_hits_q2=$(psql_pg bench_postgis "SELECT count(*) FROM my_mapdata WHERE ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography, 10000, true);")
pg_hits_q3=$(psql_pg bench_postgis "SELECT count(*) FROM my_mapdata WHERE ST_Intersects(geom, ST_MakeEnvelope(-105.20, 39.60, -104.70, 40.00, 4326));")
pg_hits_q4=$(psql_pg bench_postgis "SELECT count(*) FROM rivers WHERE ST_Intersects(geom, ST_MakeEnvelope(-124.4, 32.5, -114.1, 42.0, 4326));")

s2_hits_q1=$(psql_yb bench_s2 "SELECT count(*) FROM my_mapdata WHERE md_pk IN (SELECT spatial_candidates('my_mapdata', ST_MakeEnvelope(-105.0925, 40.5703, -105.0625, 40.6003, 4326))) AND ST_DistanceSphere(geom, ST_GeomFromText('POINT(-105.0775 40.5853)', 4326)) <= 1000;")
s2_hits_q2=$(psql_yb bench_s2 "SELECT count(*) FROM my_mapdata WHERE md_pk IN (SELECT spatial_candidates('my_mapdata', ST_MakeEnvelope(-105.20, 40.47, -104.95, 40.70, 4326))) AND ST_DistanceSphere(geom, ST_GeomFromText('POINT(-105.0775 40.5853)', 4326)) <= 10000;")
s2_hits_q3=$(psql_yb bench_s2 "SELECT count(*) FROM my_mapdata WHERE md_pk IN (SELECT spatial_candidates('my_mapdata', ST_MakeEnvelope(-105.20, 39.60, -104.70, 40.00, 4326))) AND ST_Intersects(geom, ST_MakeEnvelope(-105.20, 39.60, -104.70, 40.00, 4326));")
s2_hits_q4=$(psql_yb bench_s2 "SELECT count(*) FROM rivers WHERE id IN (SELECT spatial_candidates('rivers', ST_MakeEnvelope(-124.4, 32.5, -114.1, 42.0, 4326))) AND ST_Intersects(geom, ST_MakeEnvelope(-124.4, 32.5, -114.1, 42.0, 4326));")

# Dan's hit counts (hardcoded per the queries' structure)
d_hits_q1=$(psql_yb bench_dans "WITH nearby_cells AS (SELECT * FROM geohash_cells_for_bbox(-105.0892, 40.5763, -105.0658, 40.5943, 6) h) SELECT count(*) FROM my_mapdata WHERE left(geo_hash10, 6) = ANY(ARRAY(SELECT h FROM nearby_cells)) AND ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography, 1000, true);")
d_hits_q2=$(psql_yb bench_dans "WITH nearby_cells AS (SELECT * FROM geohash_cells_for_bbox(-105.20, 40.47, -104.95, 40.70, 5) h) SELECT count(*) FROM my_mapdata WHERE left(geo_hash10, 5) = ANY(ARRAY(SELECT h FROM nearby_cells)) AND ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography, 10000, true);")
d_hits_q3=$(psql_yb bench_dans "WITH covering AS (SELECT * FROM geohash_cells_for_bbox(-105.20, 39.60, -104.70, 40.00) h) SELECT count(*) FROM my_mapdata WHERE left(geo_hash10, 5) = ANY(ARRAY(SELECT h FROM covering)) AND ST_Intersects(geom, ST_MakePolygon(ARRAY[-105.20, -104.70, -104.70, -105.20, -105.20], ARRAY[39.60,  39.60,  40.00,  40.00,  39.60]));")
d_hits_q4=$(psql_yb bench_dans "SELECT count(*) FROM rivers WHERE ST_Intersects(geom, ST_MakePolygon(ARRAY[-124.4, -114.1, -114.1, -124.4, -124.4], ARRAY[32.5, 32.5, 42.0, 42.0, 32.5]));")

# ---- Timings ----
echo ""
echo "[bench] running Q1 x $ITERS on 3 engines..."
pg_t_q1=$(run_query pg bench_postgis  "$ROOT/queries/Q1_postgis.sql")
d_t_q1=$( run_query yb bench_dans     "$ROOT/queries/Q1_dans.sql")
s2_t_q1=$(run_query yb bench_s2       "$ROOT/queries/Q1_s2.sql")

echo "[bench] running Q2 x $ITERS on 3 engines..."
pg_t_q2=$(run_query pg bench_postgis  "$ROOT/queries/Q2_postgis.sql")
d_t_q2=$( run_query yb bench_dans     "$ROOT/queries/Q2_dans.sql")
s2_t_q2=$(run_query yb bench_s2       "$ROOT/queries/Q2_s2.sql")

echo "[bench] running Q3 x $ITERS on 3 engines..."
pg_t_q3=$(run_query pg bench_postgis  "$ROOT/queries/Q3_postgis.sql")
d_t_q3=$( run_query yb bench_dans     "$ROOT/queries/Q3_dans.sql")
s2_t_q3=$(run_query yb bench_s2       "$ROOT/queries/Q3_s2.sql")

echo "[bench] running Q4 x $ITERS on 3 engines..."
pg_t_q4=$(run_query pg bench_postgis  "$ROOT/queries/Q4_postgis.sql")
d_t_q4=$( run_query yb bench_dans     "$ROOT/queries/Q4_dans.sql")
s2_t_q4=$(run_query yb bench_s2       "$ROOT/queries/Q4_s2.sql")

# ---- Output markdown ----
cat > "$RESULTS/benchmark.md" <<EOF
# Spatial index benchmark: PostGIS vs Dan's (geohash) vs yb_geospatial_s2

Dataset: 344,688 POI rows (Dan's \`19_mapData.pipe\`)
Date: $(date)
Timings: median of 5 runs (1 warmup discarded), in milliseconds

## Correctness (rows returned, ignoring order)

| Query | Description | PostGIS | S2 (ours) | Dan's (geohash) |
|-------|-------------|--------:|----------:|----------------:|
| Q1 | Points within **1 km** of Fort Collins | $pg_hits_q1 | $s2_hits_q1 | $d_hits_q1 |
| Q2 | Points within **10 km** of Fort Collins | $pg_hits_q2 | $s2_hits_q2 | $d_hits_q2 |
| Q3 | Points inside Denver-metro box (~40 km) | $pg_hits_q3 | $s2_hits_q3 | $d_hits_q3 |
| Q4 | **Rivers** intersecting California envelope (5,000 LineStrings) | $pg_hits_q4 | $s2_hits_q4 | $d_hits_q4 |

## Latency (median ms)

| Query | PostGIS | S2 (ours) | Dan's (geohash) |
|-------|--------:|----------:|----------------:|
| Q1 | $pg_t_q1 | $s2_t_q1 | $d_t_q1 |
| Q2 | $pg_t_q2 | $s2_t_q2 | $d_t_q2 |
| Q3 | $pg_t_q3 | $s2_t_q3 | $d_t_q3 |
| Q4 | $pg_t_q4 | $s2_t_q4 | $d_t_q4 (seq scan) |

EOF

cat "$RESULTS/benchmark.md"
echo ""
echo "[bench] report at $RESULTS/benchmark.md"
