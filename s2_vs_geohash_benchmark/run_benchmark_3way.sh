#!/usr/bin/env bash
# ============================================================================
# run_benchmark_3way.sh
#
# Variant of run_benchmark.sh that drops c_geohash from the comparison.
# Runs the four perf queries (Q2 / Q3 / Q4 / Q6) on three engines:
#   * PostGIS (vanilla PG15 / GiST)        -- correctness oracle
#   * Dan's pure-SQL geohash on YB         -- "the demo"
#   * yb_geospatial_s2 on YB (S2)          -- the production candidate
#
# Goal: confirm the README's PostGIS-vs-Dan's-vs-S2 numbers are still
# accurate after recent changes. The c_geohash extension is deliberately
# excluded -- its role is the structural distortion comparison against S2,
# which lives in geohash-related/distortion_test/, not here.
#
# 3 iterations per query (1 warmup discarded, median of remaining 2).
# Writes results/benchmark_3way.md.
# ============================================================================
set -euo pipefail

ROOT=$(cd "$(dirname "$0")"; pwd)
RESULTS=$ROOT/results
mkdir -p "$RESULTS"

YB_BIN=/net/dev-server-te-yenchou/share/code/yugabyte-db/build/latest/postgres/bin
PG_BIN=/usr/pgsql-15/bin

psql_yb()  { $YB_BIN/ysqlsh -h 127.0.0.1 -p 5433 -U yugabyte -d "$1" -qAtX -c "$2"; }
psql_pg()  { $PG_BIN/psql   -h 127.0.0.1 -p 54321 -d "$1" -qAtX -c "$2"; }

ITERS=3   # 1 warmup + 2 measured (faster than the 6 the original uses)
WARMUP=1

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
pg_hits_q2=$(psql_pg bench_postgis "SELECT count(*) FROM my_mapdata WHERE ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography, 50000, true);")
pg_hits_q3=$(psql_pg bench_postgis "SELECT count(*) FROM my_mapdata WHERE ST_Intersects(geom, ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326));")
pg_hits_q4=$(psql_pg bench_postgis "SELECT count(*) FROM rivers WHERE ST_Intersects(geom, ST_MakeEnvelope(-125.0, 30.0, -100.0, 50.0, 4326));")

s2_hits_q2=$(psql_yb bench_s2 "SELECT count(*) FROM my_mapdata WHERE md_pk IN (SELECT spatial_candidates('my_mapdata', ST_MakeEnvelope(-105.68, 40.08, -104.48, 41.08, 4326))) AND ST_DistanceSpheroid(geom, ST_GeomFromText('POINT(-105.0775 40.5853)', 4326)) <= 50000;")
s2_hits_q3=$(psql_yb bench_s2 "SELECT count(*) FROM my_mapdata WHERE md_pk IN (SELECT spatial_candidates('my_mapdata', ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326))) AND ST_Intersects(geom, ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326));")
s2_hits_q4=$(psql_yb bench_s2 "SELECT count(*) FROM rivers WHERE id IN (SELECT spatial_candidates('rivers', ST_MakeEnvelope(-125.0, 30.0, -100.0, 50.0, 4326))) AND ST_Intersects(geom, ST_MakeEnvelope(-125.0, 30.0, -100.0, 50.0, 4326));")

d_hits_q2=$(psql_yb bench_dans "WITH nearby_cells AS (SELECT * FROM geohash_cells_for_bbox(-105.68, 40.08, -104.48, 41.08, 5) h) SELECT count(*) FROM my_mapdata WHERE left(geo_hash10, 5) = ANY(ARRAY(SELECT h FROM nearby_cells)) AND ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography, 50000, true);")
d_hits_q3=$(psql_yb bench_dans "WITH covering AS (SELECT * FROM geohash_cells_for_bbox(-106.20, 38.80, -103.70, 40.80, 5) h) SELECT count(*) FROM my_mapdata WHERE left(geo_hash10, 5) = ANY(ARRAY(SELECT h FROM covering)) AND ST_Intersects(geom, ST_MakePolygon(ARRAY[-106.20, -103.70, -103.70, -106.20, -106.20], ARRAY[38.80, 38.80, 40.80, 40.80, 38.80]));")
d_hits_q4=$(psql_yb bench_dans "SELECT count(*) FROM rivers WHERE ST_Intersects(geom, ST_MakePolygon(ARRAY[-125.0, -100.0, -100.0, -125.0, -125.0], ARRAY[30.0, 30.0, 50.0, 50.0, 30.0]));")

# Q6 KNN -- compare top-10 IDs between engines.
# Tolerant: if any engine's KNN call fails (e.g. spatial_knn missing in
# bench_s2), record "n/a" instead of aborting the whole benchmark.
pg_knn_q6=$(psql_pg bench_postgis "SELECT string_agg(md_pk::text, ',' ORDER BY md_pk) FROM (SELECT md_pk FROM my_mapdata ORDER BY geom <-> ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326) LIMIT 10) s;" 2>/dev/null || echo "")
s2_knn_q6=$(psql_yb bench_s2      "SELECT string_agg(id::text, ',' ORDER BY id) FROM spatial_knn('my_mapdata', ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326), 10, 'md_pk');" 2>/dev/null || echo "")
d_knn_q6=$( psql_yb bench_dans    "SELECT string_agg(md_pk::text, ',' ORDER BY md_pk) FROM (SELECT md_pk FROM my_mapdata ORDER BY geom <-> ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326) LIMIT 10) s;" 2>/dev/null || echo "")
if [ -z "$s2_knn_q6" ];                        then s2_q6_ok="(spatial_knn missing)"
elif [ "$pg_knn_q6" = "$s2_knn_q6" ];          then s2_q6_ok="matches PostGIS"
else                                                 s2_q6_ok="differs: $s2_knn_q6"; fi
if [ -z "$d_knn_q6" ];                         then d_q6_ok="(KNN failed)"
elif [ "$pg_knn_q6" = "$d_knn_q6" ];           then d_q6_ok="matches PostGIS"
else                                                 d_q6_ok="differs: $d_knn_q6"; fi

# ---- Timings ----
echo ""
echo "[bench-3way] running Q2 x $ITERS on 3 engines..."
pg_t_q2=$(run_query pg bench_postgis "$ROOT/queries/performance/Q2_postgis.sql")
d_t_q2=$( run_query yb bench_dans    "$ROOT/queries/performance/Q2_dans.sql")
s2_t_q2=$(run_query yb bench_s2      "$ROOT/queries/performance/Q2_s2.sql")

echo "[bench-3way] running Q3 x $ITERS on 3 engines..."
pg_t_q3=$(run_query pg bench_postgis "$ROOT/queries/performance/Q3_postgis.sql")
d_t_q3=$( run_query yb bench_dans    "$ROOT/queries/performance/Q3_dans.sql")
s2_t_q3=$(run_query yb bench_s2      "$ROOT/queries/performance/Q3_s2.sql")

echo "[bench-3way] running Q4 x $ITERS on 3 engines..."
pg_t_q4=$(run_query pg bench_postgis "$ROOT/queries/performance/Q4_postgis.sql")
d_t_q4=$( run_query yb bench_dans    "$ROOT/queries/performance/Q4_dans.sql")
s2_t_q4=$(run_query yb bench_s2      "$ROOT/queries/performance/Q4_s2.sql")

echo "[bench-3way] running Q6 x $ITERS on 3 engines..."
pg_t_q6=$(run_query pg bench_postgis "$ROOT/queries/performance/Q6_postgis.sql")
d_t_q6=$( run_query yb bench_dans    "$ROOT/queries/performance/Q6_dans.sql")
s2_t_q6=$(run_query yb bench_s2      "$ROOT/queries/performance/Q6_s2.sql")

cat > "$RESULTS/benchmark_3way.md" <<EOF
# Spatial-index 3-way benchmark: PostGIS vs Dan's pure-SQL vs yb_geospatial_s2

Dataset: 344,688 POIs + 100,000 rivers
Date: $(date)
Iterations: $ITERS per query ($WARMUP warmup discarded, median of remaining)

## Correctness (rows returned, ignoring order)

| Query | Description | PostGIS | S2 | Dan's |
|-------|-------------|--------:|---:|------:|
| Q2 | Points within **50 km** of Fort Collins | $pg_hits_q2 | $s2_hits_q2 | $d_hits_q2 |
| Q3 | Points inside **~200 km** Colorado Front Range box | $pg_hits_q3 | $s2_hits_q3 | $d_hits_q3 |
| Q4 | **Rivers** intersecting western-US envelope | $pg_hits_q4 | $s2_hits_q4 | $d_hits_q4 |
| Q6 | **KNN: 10 nearest POIs** to Fort Collins | 10 | $s2_q6_ok | $d_q6_ok |

## Latency (median ms)

| Query | PostGIS | S2 | Dan's |
|-------|--------:|---:|------:|
| Q2 | $pg_t_q2 | $s2_t_q2 | $d_t_q2 |
| Q3 | $pg_t_q3 | $s2_t_q3 | $d_t_q3 |
| Q4 | $pg_t_q4 | $s2_t_q4 | $d_t_q4 *(seq scan)* |
| Q6 | $pg_t_q6 *(GiST KNN)* | $s2_t_q6 *(spatial_knn)* | $d_t_q6 *(seq scan)* |
EOF

echo ""
echo "=== results/benchmark_3way.md ==="
cat "$RESULTS/benchmark_3way.md"
