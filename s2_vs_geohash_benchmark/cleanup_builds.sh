#!/usr/bin/env bash
# ============================================================================
# cleanup_builds.sh
#
# Wipes all compiled build artifacts, generated data, and local databases
# associated with the benchmark. Does NOT touch any source code.
#
# Useful for completely resetting the environment before a fresh run of
# bootstrap.sh, or freeing up disk space (the YB build folder is ~10-20GB).
# ============================================================================
set -euo pipefail

BENCH_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CODE_ROOT=$(cd "$BENCH_ROOT/../.."; pwd)

YB_ROOT=${YB_ROOT:-$CODE_ROOT/yugabyte-db}
DEPS_ROOT=${DEPS_ROOT:-$CODE_ROOT/deps}

echo "===================================================================="
echo "WARNING: This will delete the ENTIRE YugabyteDB build folder,"
echo "         S2 builds, and all local benchmark databases."
echo "         Source code will not be modified."
echo "===================================================================="
read -p "Are you sure you want to proceed? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]
then
    echo "Aborted."
    exit 1
fi

echo "[cleanup] 1. Stopping any running databases..."
pkill -9 -f "yb-master|yb-tserver" 2>/dev/null || true
pkill -9 -f "postgres.*pg_data" 2>/dev/null || true
# Give them a second to die and release file locks
sleep 1

echo "[cleanup] 2. Removing YugabyteDB build artifacts..."
if [ -d "$YB_ROOT/build" ]; then
    rm -rf "$YB_ROOT/build"
    echo "  -> Deleted $YB_ROOT/build"
else
    echo "  -> YB build already gone."
fi

echo "[cleanup] 3. Removing S2 Geometry build artifacts..."
if [ -d "$DEPS_ROOT/s2geometry/build" ]; then
    rm -rf "$DEPS_ROOT/s2geometry/build"
    echo "  -> Deleted $DEPS_ROOT/s2geometry/build"
fi
if [ -d "$DEPS_ROOT/s2-install" ]; then
    rm -rf "$DEPS_ROOT/s2-install"
    echo "  -> Deleted $DEPS_ROOT/s2-install"
fi

echo "[cleanup] 4. Removing local benchmark databases & generated data..."
if [ -d "$BENCH_ROOT/pg_data" ]; then
    rm -rf "$BENCH_ROOT/pg_data"
    echo "  -> Deleted $BENCH_ROOT/pg_data"
fi
if [ -d "$BENCH_ROOT/data" ]; then
    rm -rf "$BENCH_ROOT/data"
    echo "  -> Deleted $BENCH_ROOT/data"
fi
if [ -d "/tmp/yugabyted-bench" ]; then
    rm -rf "/tmp/yugabyted-bench"
    echo "  -> Deleted /tmp/yugabyted-bench"
fi
rm -f "/tmp/yugabyted-start.log"

echo "[cleanup] Done. Environment is completely clean."
echo "Run ./bootstrap.sh to rebuild everything from scratch."