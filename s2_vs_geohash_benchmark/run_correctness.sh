#!/usr/bin/env bash
# ============================================================================
# run_correctness.sh
#
# Runs every queries/correctness/bug_*.sql against the three engines and
# prints a side-by-side summary showing where Dan's geohash silently
# returns the wrong answer or crashes.  Unlike run_benchmark.sh this has
# no iteration / median logic -- each query runs exactly once.
# ============================================================================
set -euo pipefail

ROOT=$(cd "$(dirname "$0")"; pwd)
YB_BIN=/net/dev-server-te-yenchou/share/code/yugabyte-db/build/latest/postgres/bin
PG_BIN=/usr/pgsql-15/bin

summarize() {
  # Keep just one-line result or flag an ERROR / crash.
  local out="$1"
  if echo "$out" | grep -qE 'ERROR: '; then
    echo "ERROR (crash)"
  else
    echo "$out" | grep -vE '^(ysqlsh:|psql:|NOTICE|CONTEXT|LINE)' | tail -n 1
  fi
}
psql_yb() {
  local out
  out=$("$YB_BIN/ysqlsh" -h 127.0.0.1 -p 5433 -U yugabyte -d "$1" -qAtX -f "$2" 2>&1)
  summarize "$out"
}
psql_pg() {
  local out
  out=$("$PG_BIN/psql" -h 127.0.0.1 -p 54321 -d "$1" -qAtX -f "$2" 2>&1)
  summarize "$out"
}

CASES=(
  "bug_crossing_lines|Two 2-vertex lines crossing at (5,5)"
  "bug_line_closure  |Open C-shape LineString vs inner square"
  "bug_polygon_hole  |Point (5,5) inside the hole of a donut polygon"
)

printf "\n"
printf "%-50s | %-8s | %-8s | %-s\n" "Scenario" "PostGIS" "S2" "Dan's"
printf "%-50s-+-%-8s-+-%-8s-+-%-s\n" "$(printf '%*s' 50 | tr ' ' -)" \
       "--------" "--------" "--------"

for row in "${CASES[@]}"; do
  prefix="${row%%|*}"; prefix="${prefix// /}"
  label="${row#*|}"

  pg_out=$(psql_pg bench_postgis "$ROOT/queries/correctness/${prefix}_postgis.sql")
  s2_out=$(psql_yb bench_s2      "$ROOT/queries/correctness/${prefix}_s2.sql")
  d_out=$( psql_yb bench_dans    "$ROOT/queries/correctness/${prefix}_dans.sql")

  printf "%-50s | %-8s | %-8s | %s\n" "$label" "$pg_out" "$s2_out" "$d_out"
done

printf "\n"
