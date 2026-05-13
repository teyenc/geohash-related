#!/usr/bin/env bash
# ============================================================================
# bootstrap.sh  --  end-to-end rebuild of the whole benchmark, from scratch.
#
# Use case: you have the YugabyteDB source tree but nothing else - no S2 lib,
# no PostGIS DB, no YB extension built, no benchmark DBs, no data loaded.
# This script does the whole thing and ends with results/benchmark.md.
#
# What it does (each stage is idempotent - skips if already done):
#   1. Verify system prerequisites (PG15+PostGIS, GEOS 3.14, YB source tree).
#   2. Clone Dan's demo repo (for his SQL + the 344K POI pipe file).
#   3. Clone + build google/s2geometry with the YB toolchain + libc++.
#   4. Build YugabyteDB postgres target if not already built.
#   5. Build + install the yb_geospatial_s2 extension.
#   6. Check that a YB cluster is running on 127.0.0.1:5433 (fail with
#      a helpful message if not - we don't auto-start YB for safety).
#   7. Run the four setup scripts (00..03) to create bench_postgis,
#      bench_dans, bench_s2 and load data.
#   8. Run run_benchmark.sh and print results/benchmark.md.
#
# Expected runtime from a cold machine: ~30-45 min (YB build dominates).
# On a machine where YB + S2 are already built: ~5 min.
#
# All paths are overridable by env vars:
#   YB_ROOT   - YugabyteDB source tree            (default: <SHARE>/code/yugabyte-db)
#   DEPS_ROOT - where S2 and other vendored deps live  (default: <SHARE>/code/deps)
#   DAN_ROOT  - Dan's geospatial_v05 checkout     (default: <SHARE>/code/geospatial_v05)
#   PG_PORT   - local PG15 port for the PostGIS bench DB  (default: 54321)
# ============================================================================
set -euo pipefail

BENCH_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# BENCH_ROOT = .../code/geohash-related/s2_vs_geohash_benchmark
# CODE_ROOT  = .../code        (two levels up)
CODE_ROOT=$(cd "$BENCH_ROOT/../.."; pwd)

YB_ROOT=${YB_ROOT:-$CODE_ROOT/yugabyte-db}
DEPS_ROOT=${DEPS_ROOT:-$CODE_ROOT/deps}
DAN_ROOT=${DAN_ROOT:-$CODE_ROOT/geospatial_v05}
PG_PORT=${PG_PORT:-54321}

# -- Pretty printing -----------------------------------------------------------
log()  { printf '\n\033[1;36m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[bootstrap WARN]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[bootstrap ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# ============================================================================
# Stage 1: system prerequisites
# ============================================================================
log "Stage 1/8: checking system prerequisites"

[ -d "$YB_ROOT" ]                            || die "YB source not found at $YB_ROOT (export YB_ROOT=...)"
[ -x /usr/pgsql-15/bin/initdb ]              || die "PostgreSQL 15 not installed. Try: sudo dnf install postgresql15-server postgis35_15"
[ -x /usr/pgsql-15/bin/psql ]                || die "PG15 psql missing"
[ -f /usr/pgsql-15/share/extension/postgis.control ] \
                                             || die "PostGIS 3.x not installed. Try: sudo dnf install postgis35_15"
[ -x /usr/geos314/bin/geos-config ]          || die "GEOS 3.14 not found at /usr/geos314. Our extension's Makefile hardcodes this path."
command -v cmake    >/dev/null               || die "cmake not on PATH (need it to build S2)"
command -v git      >/dev/null               || die "git not on PATH"
command -v python3  >/dev/null               || die "python3 not on PATH (needed for gen_rivers.py)"

# YB toolchain paths -- discovered from yb_build
YB_THIRDPARTY=$(ls -d /opt/yb-build/thirdparty/yugabyte-db-thirdparty-v*-almalinux8-x86_64-clang21 2>/dev/null | tail -1)
YB_LLVM=$(ls -d /opt/yb-build/llvm/yb-llvm-v21*-almalinux8-x86_64 2>/dev/null | tail -1)
[ -n "$YB_THIRDPARTY" ] || die "YB thirdparty not installed at /opt/yb-build/thirdparty/... (run ./yb_build.sh once to provision)"
[ -n "$YB_LLVM" ]       || die "YB LLVM toolchain not installed at /opt/yb-build/llvm/..."

log "  YB_ROOT       = $YB_ROOT"
log "  YB_THIRDPARTY = $YB_THIRDPARTY"
log "  YB_LLVM       = $YB_LLVM"
log "  DEPS_ROOT     = $DEPS_ROOT"
log "  DAN_ROOT      = $DAN_ROOT"

# ============================================================================
# Stage 2: Dan's demo
# ============================================================================
log "Stage 2/8: Dan's geospatial_v05 demo (for his SQL modules + 344K POI data)"

if [ ! -f "$DAN_ROOT/20 - sql/19_mapData.pipe" ]; then
  log "  cloning geospatial_v05..."
  mkdir -p "$(dirname "$DAN_ROOT")"
  git clone https://github.com/farrell0-yb/geospatial_v05.git "$DAN_ROOT"
else
  log "  already present at $DAN_ROOT"
fi
[ -s "$DAN_ROOT/20 - sql/19_mapData.pipe" ] || die "19_mapData.pipe not found in Dan's tree"

# ============================================================================
# Stage 3: build google/s2geometry
# ============================================================================
log "Stage 3/8: google/s2geometry library"

S2_INSTALL=$DEPS_ROOT/s2-install
if [ ! -f "$S2_INSTALL/lib64/libs2.a" ]; then
  log "  cloning and building S2 (this takes ~3 min)..."
  mkdir -p "$DEPS_ROOT"
  cd "$DEPS_ROOT"
  [ -d s2geometry ] || git clone --depth 1 https://github.com/google/s2geometry.git
  cd s2geometry
  rm -rf build && mkdir build && cd build

  LIBCXX=$YB_THIRDPARTY/installed/uninstrumented/libcxx
  cmake .. \
    -DCMAKE_C_COMPILER=$YB_LLVM/bin/clang \
    -DCMAKE_CXX_COMPILER=$YB_LLVM/bin/clang++ \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=$S2_INSTALL \
    -DFETCH_ABSEIL=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTS=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DWITH_PYTHON=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_CXX_FLAGS="-stdlib=libc++ -nostdinc++ -isystem $LIBCXX/include/c++/v1 -std=c++23" \
    -DCMAKE_EXE_LINKER_FLAGS="-stdlib=libc++ -L$LIBCXX/lib -Wl,-rpath,$LIBCXX/lib" \
    -DCMAKE_SHARED_LINKER_FLAGS="-stdlib=libc++ -L$LIBCXX/lib -Wl,-rpath,$LIBCXX/lib" \
    > /dev/null
  cmake --build . -j"$(nproc)"
  cmake --install . > /dev/null
  log "  S2 installed at $S2_INSTALL"
else
  log "  already built at $S2_INSTALL"
fi

# ============================================================================
# Stage 4: build YB (full build -- postgres, yb-master, yb-tserver)
# ============================================================================
log "Stage 4/8: YugabyteDB full build"

# We need more than just postgres -- yugabyted launches yb-master and yb-tserver
# in Stage 6, and their shared libraries have to match the postgres side.
# A partial `--target postgres` build leaves yb-master with stale symbols.
#
# The idempotency probe: both ysqlsh AND a recent yb-master must exist.
if [ ! -x "$YB_ROOT/build/latest/postgres/bin/ysqlsh" ] \
   || [ ! -x "$YB_ROOT/build/latest/bin/yb-master" ]; then
  log "  running full yb_build.sh (this takes 20-40 min first time)..."
  cd "$YB_ROOT"
  export YB_REMOTE_COMPILATION=0  # force local compile so it sees GEOS
  ./yb_build.sh release --skip-java --no-tests
else
  log "  already built at $YB_ROOT/build/latest/"
fi

# ============================================================================
# Stage 5: yb_geospatial_s2 extension
# ============================================================================
log "Stage 5/8: yb_geospatial_s2 extension"

YB_EXT_BUILD=$YB_ROOT/build/latest/postgres_build/yb-extensions
YB_EXT_INSTALL=$YB_ROOT/build/latest/postgres/share/extension

if [ ! -f "$YB_ROOT/build/latest/postgres/lib/yb_geospatial_s2.so" ] \
   || [ ! -f "$YB_EXT_INSTALL/yb_geospatial_s2--1.0.sql" ]; then
  log "  compiling + installing extension (forcing local compile to see GEOS)..."
  [ -d "$YB_EXT_BUILD/yb_geospatial_s2" ] || die "extension source not found in YB build tree (was yb_build.sh skipped?)"
  export YB_REMOTE_COMPILATION=0
  bash "$YB_EXT_BUILD/make.sh" -C "$YB_EXT_BUILD/yb_geospatial_s2"
  bash "$YB_EXT_BUILD/make.sh" -C "$YB_EXT_BUILD/yb_geospatial_s2" install
else
  log "  already installed"
fi

# ============================================================================
# Stage 6: YB cluster running? If not, start one with yugabyted.
# ============================================================================
log "Stage 6/8: YB cluster"

YB_YSQL=$YB_ROOT/build/latest/postgres/bin/ysqlsh
YUGABYTED=$YB_ROOT/bin/yugabyted
YUGABYTED_BASE=${YUGABYTED_BASE:-/tmp/yugabyted-bench}

if $YB_YSQL -h 127.0.0.1 -p 5433 -U yugabyte -c "SELECT 1" >/dev/null 2>&1; then
  log "  cluster already running and reachable on 127.0.0.1:5433"
else
  # Clean up any stale yb-master / yb-tserver processes from prior runs
  if pgrep -f "yb-master|yb-tserver" >/dev/null; then
    warn "  stale YB processes detected, killing them..."
    pkill -9 -f "yb-master" || true
    pkill -9 -f "yb-tserver" || true
    sleep 2
  fi

  log "  starting a single-node cluster with yugabyted (base_dir=$YUGABYTED_BASE)"
  mkdir -p "$YUGABYTED_BASE"
  # --advertise_address=127.0.0.1 forces localhost YSQL on :5433
  "$YUGABYTED" start \
      --base_dir="$YUGABYTED_BASE" \
      --advertise_address=127.0.0.1 \
      >/tmp/yugabyted-start.log 2>&1 \
    || { warn "yugabyted start failed; see /tmp/yugabyted-start.log and $YUGABYTED_BASE/logs/"; exit 1; }

  # Wait for YSQL to come up (up to 60s)
  for i in $(seq 1 30); do
    if $YB_YSQL -h 127.0.0.1 -p 5433 -U yugabyte -c "SELECT 1" >/dev/null 2>&1; then
      log "  cluster is up (took ${i}x2 sec)"
      break
    fi
    sleep 2
  done

  $YB_YSQL -h 127.0.0.1 -p 5433 -U yugabyte -c "SELECT 1" >/dev/null 2>&1 \
    || die "YB cluster did not come up after 60s. Check $YUGABYTED_BASE/logs/"
fi

# ============================================================================
# Stage 7: create the three benchmark databases + load data
# ============================================================================
log "Stage 7/8: creating bench_postgis, bench_dans, bench_s2, bench_cgeo + loading data"

cd "$BENCH_ROOT"
log "  [postgis] fresh local PG15 cluster on :$PG_PORT + 344K POIs + GiST"
PG_PORT=$PG_PORT ./setup/00_setup_postgis.sh

log "  [dans]    creating bench_dans in YB + Dan's SQL + 344K POIs (~90s)"
./setup/01_setup_yb_dans.sh

log "  [s2]      creating bench_s2 in YB + yb_geospatial_s2 + 344K POIs (~60s)"
./setup/02_setup_yb_s2.sh

log "  [cgeo]    creating bench_cgeo in YB + c_geohash + 344K POIs (~60s)"
./setup/04_setup_yb_cgeo.sh

# 03 must run AFTER 04 because it now also loads rivers into bench_cgeo
# (which requires the c_geohash extension to already be installed there).
log "  [rivers]  generating 100K synthetic rivers + loading into all 4 DBs"
./setup/03_setup_rivers.sh

# ============================================================================
# Stage 8: run the benchmark + print results
# ============================================================================
log "Stage 8/8: running benchmark (Q1-Q4 x 6 iterations x 3 engines, ~100s)"

./run_benchmark.sh

echo ""
echo "=========================================================================="
echo "  Benchmark complete."
echo "=========================================================================="
cat "$BENCH_ROOT/results/benchmark.md"
echo ""
echo "(report saved at: $BENCH_ROOT/results/benchmark.md)"
