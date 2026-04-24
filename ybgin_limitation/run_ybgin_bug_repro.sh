#!/usr/bin/env bash
# ============================================================================
# run_ybgin_bug_repro.sh
#
# Runs both the text[] and jsonb reproducers against a live YB cluster
# and shows the expected crash alongside the working cases.  Nothing is
# left behind (tables are dropped at the end of each script).
# ============================================================================
set -u

ROOT=$(cd "$(dirname "$0")"; pwd)
YB_BIN=${YB_BIN:-/net/dev-server-te-yenchou/share/code/yugabyte-db/build/latest/postgres/bin}
YB_DB=${YB_DB:-yugabyte}
YB_HOST=${YB_HOST:-127.0.0.1}
YB_PORT=${YB_PORT:-5433}
YB_USER=${YB_USER:-yugabyte}

psql_yb() {
  "$YB_BIN/ysqlsh" -h "$YB_HOST" -p "$YB_PORT" -U "$YB_USER" -d "$YB_DB" -X -f "$1"
}

echo "================================================================"
echo " REPRODUCER 1: text[] && ARRAY[...]"
echo "================================================================"
psql_yb "$ROOT/ybgin_bug_repro.sql"

echo ""
echo "================================================================"
echo " REPRODUCER 2: jsonb ?| ARRAY[...]"
echo "================================================================"
psql_yb "$ROOT/ybgin_bug_repro_jsonb.sql"
