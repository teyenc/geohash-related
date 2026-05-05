#!/usr/bin/env bash
# ============================================================================
# run_benchmark.sh
#
# Runs Q1..Q6 on FOUR engines:
#   * PostGIS (vanilla PG15 / GiST)               -- correctness oracle
#   * Dan's pure-SQL geohash on YB                -- old multi-precision path
#   * yb_geospatial_s2 on YB (S2 cells, int64)    -- baseline we mirror
#   * c_geohash on YB (geohash int64, this PR)    -- the new prototype
#
# 6x per query (1 warmup discarded, median of remaining 5). Writes
# results/benchmark.md.
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
# Q1:   5 km radius around Fort Collins,   padded bbox (-105.15, 40.52)  -> (-105.00, 40.65)
# Q2:  50 km radius around Fort Collins,   padded bbox (-105.68, 40.08)  -> (-104.48, 41.08)
# Q3: 200 km Colorado Front Range box,            bbox (-106.20, 38.80)  -> (-103.70, 40.80)
# Q4: western-US envelope (~5x CA area),          bbox (-125.00, 30.00)  -> (-100.00, 50.00)
pg_hits_q1=$(psql_pg bench_postgis "SELECT count(*) FROM my_mapdata WHERE ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography, 5000, true);")
pg_hits_q2=$(psql_pg bench_postgis "SELECT count(*) FROM my_mapdata WHERE ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography, 50000, true);")
pg_hits_q3=$(psql_pg bench_postgis "SELECT count(*) FROM my_mapdata WHERE ST_Intersects(geom, ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326));")
pg_hits_q4=$(psql_pg bench_postgis "SELECT count(*) FROM rivers WHERE ST_Intersects(geom, ST_MakeEnvelope(-125.0, 30.0, -100.0, 50.0, 4326));")

s2_hits_q1=$(psql_yb bench_s2 "SELECT count(*) FROM my_mapdata WHERE md_pk IN (SELECT spatial_candidates('my_mapdata', ST_MakeEnvelope(-105.15, 40.52, -105.00, 40.65, 4326))) AND ST_DistanceSpheroid(geom, ST_GeomFromText('POINT(-105.0775 40.5853)', 4326)) <= 5000;")
s2_hits_q2=$(psql_yb bench_s2 "SELECT count(*) FROM my_mapdata WHERE md_pk IN (SELECT spatial_candidates('my_mapdata', ST_MakeEnvelope(-105.68, 40.08, -104.48, 41.08, 4326))) AND ST_DistanceSpheroid(geom, ST_GeomFromText('POINT(-105.0775 40.5853)', 4326)) <= 50000;")
s2_hits_q3=$(psql_yb bench_s2 "SELECT count(*) FROM my_mapdata WHERE md_pk IN (SELECT spatial_candidates('my_mapdata', ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326))) AND ST_Intersects(geom, ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326));")
s2_hits_q4=$(psql_yb bench_s2 "SELECT count(*) FROM rivers WHERE id IN (SELECT spatial_candidates('rivers', ST_MakeEnvelope(-125.0, 30.0, -100.0, 50.0, 4326))) AND ST_Intersects(geom, ST_MakeEnvelope(-125.0, 30.0, -100.0, 50.0, 4326));")
# c_geohash hit counts (mirror of the S2 forms; cgeo_spatial_candidates +
# the same ST_DistanceSpheroid / ST_Intersects rechecks).
cg_hits_q1=$(psql_yb bench_cgeo "SELECT count(*) FROM my_mapdata WHERE md_pk IN (SELECT cgeo_spatial_candidates('my_mapdata', ST_MakeEnvelope(-105.15, 40.52, -105.00, 40.65, 4326))) AND ST_DistanceSpheroid(geom, ST_GeomFromText('POINT(-105.0775 40.5853)', 4326)) <= 5000;")
cg_hits_q2=$(psql_yb bench_cgeo "SELECT count(*) FROM my_mapdata WHERE md_pk IN (SELECT cgeo_spatial_candidates('my_mapdata', ST_MakeEnvelope(-105.68, 40.08, -104.48, 41.08, 4326))) AND ST_DistanceSpheroid(geom, ST_GeomFromText('POINT(-105.0775 40.5853)', 4326)) <= 50000;")
cg_hits_q3=$(psql_yb bench_cgeo "SELECT count(*) FROM my_mapdata WHERE md_pk IN (SELECT cgeo_spatial_candidates('my_mapdata', ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326))) AND ST_Intersects(geom, ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326));")
cg_hits_q4=$(psql_yb bench_cgeo "SELECT count(*) FROM rivers WHERE id IN (SELECT cgeo_spatial_candidates('rivers', ST_MakeEnvelope(-125.0, 30.0, -100.0, 50.0, 4326))) AND ST_Intersects(geom, ST_MakeEnvelope(-125.0, 30.0, -100.0, 50.0, 4326));")
# Q5: && bounding box overlap operator on the ~200 km Colorado Front Range box
pg_hits_q5=$(psql_pg bench_postgis "SELECT count(*) FROM my_mapdata WHERE geom && ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326);")
s2_hits_q5=$(psql_yb bench_s2 "SELECT count(*) FROM my_mapdata WHERE md_pk IN (SELECT spatial_candidates('my_mapdata', ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326))) AND geom && ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326);")
cg_hits_q5=$(psql_yb bench_cgeo "SELECT count(*) FROM my_mapdata WHERE md_pk IN (SELECT cgeo_spatial_candidates('my_mapdata', ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326))) AND geom && ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326);")

# Dan's hit counts (hardcoded per the queries' structure)
d_hits_q1=$(psql_yb bench_dans "WITH nearby_cells AS (SELECT * FROM geohash_cells_for_bbox(-105.15, 40.52, -105.00, 40.65, 5) h) SELECT count(*) FROM my_mapdata WHERE left(geo_hash10, 5) = ANY(ARRAY(SELECT h FROM nearby_cells)) AND ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography, 5000, true);")
d_hits_q2=$(psql_yb bench_dans "WITH nearby_cells AS (SELECT * FROM geohash_cells_for_bbox(-105.68, 40.08, -104.48, 41.08, 5) h) SELECT count(*) FROM my_mapdata WHERE left(geo_hash10, 5) = ANY(ARRAY(SELECT h FROM nearby_cells)) AND ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography, 50000, true);")
d_hits_q3=$(psql_yb bench_dans "WITH covering AS (SELECT * FROM geohash_cells_for_bbox(-106.20, 38.80, -103.70, 40.80, 5) h) SELECT count(*) FROM my_mapdata WHERE left(geo_hash10, 5) = ANY(ARRAY(SELECT h FROM covering)) AND ST_Intersects(geom, ST_MakePolygon(ARRAY[-106.20, -103.70, -103.70, -106.20, -106.20], ARRAY[38.80, 38.80, 40.80, 40.80, 38.80]));")
d_hits_q4=$(psql_yb bench_dans "SELECT count(*) FROM rivers WHERE ST_Intersects(geom, ST_MakePolygon(ARRAY[-125.0, -100.0, -100.0, -125.0, -125.0], ARRAY[30.0, 30.0, 50.0, 50.0, 30.0]));")
d_hits_q5=$(psql_yb bench_dans "SELECT count(*) FROM my_mapdata WHERE geom && ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326);")

# Q6: 10 nearest POIs to Fort Collins (KNN).  We compare the sorted ID lists
# from each engine to check we're returning the same neighbours.  PostGIS
# uses planar <->, while S2 and Dan's use spheroidal distance; for a dense
# local query the top-10 IDs match regardless.
pg_knn_q6=$(psql_pg bench_postgis "SELECT string_agg(md_pk::text, ',' ORDER BY md_pk) FROM (SELECT md_pk FROM my_mapdata ORDER BY geom <-> ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326) LIMIT 10) s;")
s2_knn_q6=$(psql_yb bench_s2      "SELECT string_agg(id::text, ',' ORDER BY id) FROM spatial_knn('my_mapdata', ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326), 10, 'md_pk');")
d_knn_q6=$( psql_yb bench_dans    "SELECT string_agg(md_pk::text, ',' ORDER BY md_pk) FROM (SELECT md_pk FROM my_mapdata ORDER BY geom <-> ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326) LIMIT 10) s;")
# c_geohash KNN: radius-bounded (Q6_c_geohash.sql) — 5 km bbox, recheck via
# ST_DWithin, ORDER BY dist + LIMIT 10. Worst-case sparse falls through to
# the seqscan companion file (Q6_c_geohash_seqscan.sql) which is identical
# to Q6_dans / Q6_s2_seqscan.
cg_knn_q6=$(psql_yb bench_cgeo    "SELECT string_agg(md_pk::text, ',' ORDER BY md_pk) FROM (SELECT md_pk FROM my_mapdata WHERE md_pk IN (SELECT cgeo_spatial_candidates('my_mapdata', ST_MakeEnvelope(-105.1365, 40.5403, -105.0185, 40.6303, 4326))) AND ST_DWithin(geom::geography, ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography, 5000, true) ORDER BY ST_Distance(geom::geography, ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography, true) LIMIT 10) s;")
if [ "$pg_knn_q6" = "$s2_knn_q6" ]; then s2_q6_ok="matches PostGIS"; else s2_q6_ok="differs: $s2_knn_q6"; fi
if [ "$pg_knn_q6" = "$d_knn_q6"  ]; then d_q6_ok="matches PostGIS";  else d_q6_ok="differs: $d_knn_q6";  fi
if [ "$pg_knn_q6" = "$cg_knn_q6" ]; then cg_q6_ok="matches PostGIS"; else cg_q6_ok="differs: $cg_knn_q6"; fi

# ---- Timings ----
echo ""
echo "[bench] running Q1 x $ITERS on 4 engines..."
pg_t_q1=$(run_query pg bench_postgis  "$ROOT/queries/performance/Q1_postgis.sql")
d_t_q1=$( run_query yb bench_dans     "$ROOT/queries/performance/Q1_dans.sql")
s2_t_q1=$(run_query yb bench_s2       "$ROOT/queries/performance/Q1_s2.sql")
cg_t_q1=$(run_query yb bench_cgeo     "$ROOT/queries/performance/Q1_c_geohash.sql")

echo "[bench] running Q2 x $ITERS on 4 engines..."
pg_t_q2=$(run_query pg bench_postgis  "$ROOT/queries/performance/Q2_postgis.sql")
d_t_q2=$( run_query yb bench_dans     "$ROOT/queries/performance/Q2_dans.sql")
s2_t_q2=$(run_query yb bench_s2       "$ROOT/queries/performance/Q2_s2.sql")
cg_t_q2=$(run_query yb bench_cgeo     "$ROOT/queries/performance/Q2_c_geohash.sql")

echo "[bench] running Q3 x $ITERS on 4 engines..."
pg_t_q3=$(run_query pg bench_postgis  "$ROOT/queries/performance/Q3_postgis.sql")
d_t_q3=$( run_query yb bench_dans     "$ROOT/queries/performance/Q3_dans.sql")
s2_t_q3=$(run_query yb bench_s2       "$ROOT/queries/performance/Q3_s2.sql")
cg_t_q3=$(run_query yb bench_cgeo     "$ROOT/queries/performance/Q3_c_geohash.sql")

echo "[bench] running Q4 x $ITERS on 4 engines..."
pg_t_q4=$(run_query pg bench_postgis  "$ROOT/queries/performance/Q4_postgis.sql")
d_t_q4=$( run_query yb bench_dans     "$ROOT/queries/performance/Q4_dans.sql")
s2_t_q4=$(run_query yb bench_s2       "$ROOT/queries/performance/Q4_s2.sql")
cg_t_q4=$(run_query yb bench_cgeo     "$ROOT/queries/performance/Q4_c_geohash.sql")

echo "[bench] running Q5 x $ITERS on 4 engines..."
pg_t_q5=$(run_query pg bench_postgis  "$ROOT/queries/performance/Q5_postgis.sql")
d_t_q5=$( run_query yb bench_dans     "$ROOT/queries/performance/Q5_dans.sql")
s2_t_q5=$(run_query yb bench_s2       "$ROOT/queries/performance/Q5_s2.sql")
cg_t_q5=$(run_query yb bench_cgeo     "$ROOT/queries/performance/Q5_c_geohash.sql")

echo "[bench] running Q6 x $ITERS on 4 engines..."
pg_t_q6=$(run_query pg bench_postgis  "$ROOT/queries/performance/Q6_postgis.sql")
d_t_q6=$( run_query yb bench_dans     "$ROOT/queries/performance/Q6_dans.sql")
s2_t_q6=$(run_query yb bench_s2       "$ROOT/queries/performance/Q6_s2.sql")
cg_t_q6=$(run_query yb bench_cgeo     "$ROOT/queries/performance/Q6_c_geohash.sql")

# ---- Output markdown ----
cat > "$RESULTS/benchmark.md" <<EOF
# Spatial index benchmark: PostGIS vs Dan's vs yb_geospatial_s2 vs c_geohash

Dataset: 344,688 POI rows (Dan's \`19_mapData.pipe\`) + 100,000 synthetic rivers
Date: $(date)
Timings: median of 5 runs (1 warmup discarded), in milliseconds

## Correctness (rows returned, ignoring order)

| Query | Description | PostGIS | S2 | Dan's | c_geohash |
|-------|-------------|--------:|---:|------:|----------:|
| Q1 | Points within **5 km** of Fort Collins | $pg_hits_q1 | $s2_hits_q1 | $d_hits_q1 | $cg_hits_q1 |
| Q2 | Points within **50 km** of Fort Collins | $pg_hits_q2 | $s2_hits_q2 | $d_hits_q2 | $cg_hits_q2 |
| Q3 | Points inside **~200 km** Colorado Front Range box | $pg_hits_q3 | $s2_hits_q3 | $d_hits_q3 | $cg_hits_q3 |
| Q4 | **Rivers** intersecting western-US envelope (100,000 LineStrings) | $pg_hits_q4 | $s2_hits_q4 | $d_hits_q4 | $cg_hits_q4 |
| Q5 | **&& Bounding box overlap** (~200 km box, tests index vs seq scan) | $pg_hits_q5 | $s2_hits_q5 | $d_hits_q5 | $cg_hits_q5 |
| Q6 | **KNN: 10 nearest POIs** to Fort Collins (top-k IDs) | 10 | $s2_q6_ok | $d_q6_ok | $cg_q6_ok |

## Latency (median ms)

| Query | PostGIS | S2 | Dan's | c_geohash |
|-------|--------:|---:|------:|----------:|
| Q1 | $pg_t_q1 | $s2_t_q1 | $d_t_q1 | $cg_t_q1 |
| Q2 | $pg_t_q2 | $s2_t_q2 | $d_t_q2 | $cg_t_q2 |
| Q3 | $pg_t_q3 | $s2_t_q3 | $d_t_q3 | $cg_t_q3 |
| Q4 | $pg_t_q4 | $s2_t_q4 | $d_t_q4 (seq scan) | $cg_t_q4 (NL join) |
| Q5 | $pg_t_q5 | $s2_t_q5 | $d_t_q5 (seq scan) | $cg_t_q5 |
| Q6 | $pg_t_q6 (GiST KNN) | $s2_t_q6 (spatial_knn) | $d_t_q6 (seq scan) | $cg_t_q6 (radius bbox) |

EOF

cat "$RESULTS/benchmark.md"
echo ""
echo "[bench] report at $RESULTS/benchmark.md"
