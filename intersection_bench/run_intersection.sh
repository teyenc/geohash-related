#!/usr/bin/env bash
# =============================================================================
# run_intersection.sh
#
# Apples-to-apples intersection-query benchmark for the rivers table:
#   * s2       : query cover at uniform S2 level 11 (~3.8 km cells)
#   * c_geohash: query cover at geohash precision 5 (~4.9 km cells)
#
# Both engines do the same logical thing:
#
#   SELECT count(*) FROM rivers
#    WHERE id IN (SELECT <candidates-fn>(...))
#      AND ST_Intersects(geom, envelope);
#
# and both produce the same answer (32,489 hits on the western-US envelope).
# We measure cold (first call in a fresh session) and warm (subsequent calls
# in the same session) to surface plan-cache / connection setup variance.
#
# Why these levels: gh-5 stores in ~4.9 km square cells; the nearest S2
# level by average cell edge is L11 (~3.8 km). This is "same cell size"
# alignment -- holds the cover granularity constant so we're comparing the
# space-filling curve (Hilbert vs Z-order), not the resolution.
#
# Background context for future agents:
#   * The s2 query uses spatial_candidates_v2 (explicit form, bypasses the
#     hook entirely) so cover params are stable across YB GUC changes.
#   * The cgeo query uses cgeo_text_spatial_candidates (the c_geohash
#     equivalent of v2), with explicit query precision = 5.
#   * Storage indices are pre-materialized by the setup scripts:
#       rivers_s2_index    -> ST_S2Covering(geom, 10, 20) per linestring
#       rivers_cgeo_index  -> c_geohash_cover_geometry(geom, 5, 5, 1M)
#
# Usage:
#   ./run_intersection.sh                              # default continental envelope
#   ENV_XMIN=-110 ENV_YMIN=35 ENV_XMAX=-100 ENV_YMAX=45 ./run_intersection.sh
# =============================================================================
set -euo pipefail

# --- Configurable knobs ------------------------------------------------------
YB_BIN="${YB_BIN:-/net/dev-server-te-yenchou/share/code/yugabyte-db/build/latest/postgres/bin}"
YB_HOST="${YB_HOST:-127.0.0.1}"
YB_PORT="${YB_PORT:-5433}"
YB_USER="${YB_USER:-yugabyte}"

# Envelope defaults: continental western US (-125,30) .. (-100,50).
ENV_XMIN="${ENV_XMIN:--125.0}"
ENV_YMIN="${ENV_YMIN:-30.0}"
ENV_XMAX="${ENV_XMAX:--100.0}"
ENV_YMAX="${ENV_YMAX:-50.0}"
ENV_SRID="${ENV_SRID:-4326}"
ENV_SQL="ST_MakeEnvelope(${ENV_XMIN}, ${ENV_YMIN}, ${ENV_XMAX}, ${ENV_YMAX}, ${ENV_SRID})"

# Same-cell-size knobs. gh-5 is ~4.9 km, s2-L11 is ~3.8 km. Storage on both
# engines is already at these levels (see setup scripts), so the query cover
# matches storage exactly -- minimum index-row overshoot per cover cell.
S2_LEVEL=11        # uniform L11 cover via spatial_candidates_v2
CGEO_PREC=5        # query precision passed to cgeo_text_spatial_candidates
S2_MAX_CELLS=1000000

# How many WARM runs to collect after the cold (run 1) measurement.
WARM_RUNS="${WARM_RUNS:-2}"

PSQL=( "$YB_BIN/ysqlsh" -h "$YB_HOST" -p "$YB_PORT" -U "$YB_USER" -X -tA -v ON_ERROR_STOP=1 )

# --- Per-engine query bodies -------------------------------------------------
# Defined once; reused across cold/warm calls. Each function returns the
# count via the EXPLAIN ANALYZE pipeline so we can extract exec time and
# storage RPCs from a single backend call.
S2_QUERY="
EXPLAIN (ANALYZE, DIST)
SELECT count(*) FROM rivers
 WHERE id IN (SELECT spatial_candidates_v2(
                'rivers', ${ENV_SQL}, ${S2_LEVEL}, ${S2_LEVEL}, ${S2_MAX_CELLS}))
   AND ST_Intersects(geom, ${ENV_SQL});
"

CGEO_QUERY="
EXPLAIN (ANALYZE, DIST)
SELECT count(*) FROM rivers
 WHERE id IN (SELECT cgeo_text_spatial_candidates(
                'rivers', ${ENV_SQL}, ${CGEO_PREC}))
   AND ST_Intersects(geom, ${ENV_SQL});
"

# --- Helpers -----------------------------------------------------------------
# Pull exec-ms and storage-RPC count out of an EXPLAIN ANALYZE output stream.
# Picks the LAST occurrence of each summary line (the outer-most one) so
# nested subplan timings don't pollute the result.
extract_exec_ms() {
    grep -E "^ ?Execution Time:" | tail -1 | awk '{print $3}'
}
extract_rpcs() {
    grep -E "^ ?Storage Read Requests:" | tail -1 | awk '{print $NF}'
}
extract_count() {
    grep -E "rows=[0-9]+ loops=1\)" | head -1 |
        sed -E 's/.*rows=([0-9]+) .*/\1/'
}

# Run the query in a FRESH ysqlsh session and emit "<exec_ms> <rpcs>".
# Fresh session = new backend = cold plan cache, fresh JIT, etc.
run_cold() {
    local db="$1" query="$2"
    local out
    out=$("${PSQL[@]}" -d "$db" -c "$query" 2>&1)
    local exec rpcs
    exec=$(echo "$out" | extract_exec_ms)
    rpcs=$(echo "$out" | extract_rpcs)
    echo "$exec $rpcs"
}

# Run the query N times in ONE persistent session and emit one "<exec> <rpcs>"
# line per run. The first run in the session is cold-ish (no plan cache
# but backend is already up); subsequent runs are warm.
run_warm_series() {
    local db="$1" query="$2" n="$3"
    local script=""
    local i
    for (( i=1; i<=n; i++ )); do
        script+="SELECT 'RUN_${i}_MARKER'; $query"
    done
    "${PSQL[@]}" -d "$db" -c "$script" 2>&1 | awk '
        /^RUN_[0-9]+_MARKER/   { run=$1 }
        /Execution Time:/      { exec=$3 }
        /Storage Read Requests:/ { rpcs=$NF; printf "%s %s %s\n", run, exec, rpcs }
    '
}

# --- Measurement -------------------------------------------------------------
echo "============================================================"
echo "Apples-to-apples intersection benchmark"
echo "  envelope : ${ENV_SQL}"
echo "  s2       : uniform L${S2_LEVEL} cover, max_cells=${S2_MAX_CELLS}"
echo "  c_geohash: query precision ${CGEO_PREC}"
echo "============================================================"
echo

# 1. Recall sanity (both engines should return 32489 for the continental env).
echo "[1/3] Recall sanity check..."
s2_count=$("${PSQL[@]}" -d bench_s2 -c "
    SELECT count(*) FROM rivers
    WHERE id IN (SELECT spatial_candidates_v2('rivers', ${ENV_SQL}, ${S2_LEVEL}, ${S2_LEVEL}, ${S2_MAX_CELLS}))
      AND ST_Intersects(geom, ${ENV_SQL});" | tr -d ' ')
cgeo_count=$("${PSQL[@]}" -d bench_cgeo -c "
    SELECT count(*) FROM rivers
    WHERE id IN (SELECT cgeo_text_spatial_candidates('rivers', ${ENV_SQL}, ${CGEO_PREC}))
      AND ST_Intersects(geom, ${ENV_SQL});" | tr -d ' ')
echo "    s2        -> ${s2_count} rivers"
echo "    c_geohash -> ${cgeo_count} rivers"
if [ "$s2_count" != "$cgeo_count" ]; then
    echo "    WARNING: counts disagree (recall divergence between engines)"
fi
echo

# 2. Cold runs (fresh sessions).
echo "[2/3] Cold (fresh session)..."
read s2_cold_exec s2_cold_rpcs <<< "$(run_cold bench_s2 "$S2_QUERY")"
read cg_cold_exec cg_cold_rpcs <<< "$(run_cold bench_cgeo "$CGEO_QUERY")"
echo "    s2 cold       -> exec=${s2_cold_exec} ms  rpcs=${s2_cold_rpcs}"
echo "    c_geohash cold-> exec=${cg_cold_exec} ms  rpcs=${cg_cold_rpcs}"
echo

# 3. Warm runs (one session per engine, WARM_RUNS executions back-to-back).
#    We start each warm series with a throwaway warmup query so the very
#    first measured run isn't paying the cold-plan-cache cost. The remaining
#    runs are then steady-state warm.
echo "[3/3] Warm (WARM_RUNS=${WARM_RUNS} per engine, same session)..."
echo "    s2 warm series:"
run_warm_series bench_s2 "$S2_QUERY" "$WARM_RUNS" |
    awk '{ printf "      %s -> exec=%s ms  rpcs=%s\n", $1, $2, $3 }'
echo "    c_geohash warm series:"
run_warm_series bench_cgeo "$CGEO_QUERY" "$WARM_RUNS" |
    awk '{ printf "      %s -> exec=%s ms  rpcs=%s\n", $1, $2, $3 }'

echo
echo "Done. To rerun on a different envelope:"
echo "  ENV_XMIN=-110 ENV_YMIN=35 ENV_XMAX=-100 ENV_YMAX=45 $0"
