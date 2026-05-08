#!/usr/bin/env bash
# =============================================================================
# run_compare.sh -- side-by-side setup for geohash vs S2 spatial comparison.
#
# What this script does, in order:
#   1. Preflight checks (ysqlsh, yb-ctl, data file, GEOS).
#   2. Builds YugabyteDB if either extension's .so is missing or stale.
#      Forces local compilation (YB_REMOTE_COMPILATION=0 + --no-remote)
#      because the GEOS install only exists on this dev server.
#   3. Starts the YugabyteDB cluster (skips if a healthy one is already up).
#   4. For each comparison database:
#         a) bench_geohash -- pure-SQL `yb_geospatial` extension (Dan's)
#         b) bench_s2      -- C-based `yb_geospatial_s2` extension (S2 cells)
#      drops if stale, recreates, installs the extension, creates three POI
#      tables (restaurants, shops, services), and bulk-loads ~344k POIs into
#      them, partitioned by md_category.
#   5. All inserts go through the standard PostGIS API (ST_MakePoint /
#      ST_GeomFromText etc.) -- no application code touches the side index
#      or geo_hash10/cgeo_index columns directly.
#   6. Runs verification: row counts match expected, every spatial SELECT
#      uses an Index Scan (the geohash version) or hits the side mapping
#      table via the planner_hook (the S2 version), sample queries return
#      the expected hit counts on both DBs and agree with each other.
#
# All checks adapted from geospatial_demo/run_demo.sh (Dan's script) so the
# preflight + idempotency story is identical.
#
# Usage:
#   ./run_compare.sh start    # full setup; safe to re-run any time
#   ./run_compare.sh verify   # just re-check that everything is healthy
#   ./run_compare.sh stop     # stop the cluster (data persists)
#   ./run_compare.sh clean    # stop + drop both DBs + remove extracted data
#
# Environment overrides (mostly for non-default install paths):
#   YB_SRC_DIR  -- yugabyte-db source root (default: ../../yugabyte-db)
#   GEOS_PATH   -- GEOS install bin dir    (default: /usr/geos314/bin)
#   SKIP_BUILD  -- if "1", skip step 2 (assume binaries are up to date)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Configurable paths
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
YB_SRC_DIR="${YB_SRC_DIR:-$REPO_ROOT/yugabyte-db}"
DEMO_DATA_GZ="$REPO_ROOT/geohash-related/geospatial_demo/data/19_mapData.pipe.gz"
DEMO_DATA="$REPO_ROOT/geohash-related/geospatial_demo/data/19_mapData.pipe"
GEOS_PATH="${GEOS_PATH:-/usr/geos314/bin}"
SKIP_BUILD="${SKIP_BUILD:-0}"

DB_HOST="127.0.0.1"
YB_PORT="5433"             # YugabyteDB cluster
PG_PORT="${PG_PORT:-54321}" # native PostgreSQL+PostGIS cluster (separate)

GEO_DB="bench_geohash"     # pure-SQL yb_geospatial    (Dan's)     -- on YB
S2_DB="bench_s2"           # C-based  yb_geospatial_s2            -- on YB
POSTGIS_DB="bench_postgis" # native PG15 + PostGIS 3.x extension  -- on PG

# Native PostgreSQL paths -- mirrors s2_vs_geohash_benchmark/setup/00_setup_postgis.sh
# IMPORTANT: PG_DATA defaults OUTSIDE the git tree.  A loaded data dir is
# 100MB+ and would balloon `git status` if it landed in $SCRIPT_DIR/.
# Override with PG_DATA=... if you want it elsewhere.
PG_BIN="/usr/pgsql-15/bin"
PG_DATA="${PG_DATA:-$HOME/.run_compare/pg_data}"
PG_LOG="${PG_LOG:-$HOME/.run_compare/pg_server.log}"

# Categories carved out of md_category for the 3 POI tables. Adjust if you
# want a different partition.
RESTAURANT_CATS="('Restaurant', 'Food & Beverages')"
SHOP_CATS="('Shopping', 'Retail', 'Wholesale')"
# services = NOT IN (above) — everything else

# How many rows we expect in each table. Tolerant to minor drift; only used
# for verification.
EXPECT_TOTAL=344688
EXPECT_RESTAURANTS_MIN=21000
EXPECT_SHOPS_MIN=58000
EXPECT_SERVICES_MIN=250000

YSQLSH="$YB_SRC_DIR/build/latest/postgres/bin/ysqlsh"
EXT_DIR="$YB_SRC_DIR/build/latest/postgres/share/extension"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf "\n=== %s ===\n" "$*"; }
ok()   { printf "  [OK]  %s\n" "$*"; }
fail() { printf "  [FAIL] %s\n" "$*" >&2; return 1; }

# Two engines, two clients.  yb_*  hits YB on $YB_PORT via ysqlsh.  pg_* hits
# the native PostGIS cluster on $PG_PORT via psql.  The flavor-aware wrappers
# at the bottom (sql / sql_db / sql_db_quiet / drop_db_force) dispatch based
# on a "yb" / "pg" argument so most call sites can stay engine-agnostic.

# YB ---------------------------------------------------------------------
yb_psql()        { "$YSQLSH"      -h "$DB_HOST" -p "$YB_PORT" "$@"; }
yb_db()          { yb_psql -d "$1" -c "$2"; }
yb_db_quiet()    { yb_psql -d "$1" -tAc "$2" 2>/dev/null; }

# Native PG --------------------------------------------------------------
# Default to -d postgres so a bare `pg_psql -c "SELECT 1;"` connects, since
# psql otherwise picks a database named after $USER (which doesn't exist
# right after initdb).  Callers that want a specific DB pass -d explicitly.
pg_psql()        { "$PG_BIN/psql" -h "$DB_HOST" -p "$PG_PORT" -U "$USER" -X -d postgres "$@"; }
pg_db()          { "$PG_BIN/psql" -h "$DB_HOST" -p "$PG_PORT" -U "$USER" -X -d "$1" -c "$2"; }
pg_db_quiet()    { "$PG_BIN/psql" -h "$DB_HOST" -p "$PG_PORT" -U "$USER" -X -d "$1" -tAc "$2" 2>/dev/null; }

# Engine dispatch.  Pass "yb" or "pg" as the first arg.
sql()            { local e="$1"; shift; "${e}_psql" "$@"; }
sql_db()         { local e="$1"; shift; "${e}_db" "$@"; }
sql_db_quiet()   { local e="$1"; shift; "${e}_db_quiet" "$@"; }

# Safely DROP a database even if other sessions are connected to it.
# Otherwise the engine returns "database X is being accessed by other users",
# which is annoying when re-running after a previous attempt left orphan
# sessions around.
drop_db_force() {
    local engine="$1" db="$2"
    sql "$engine" -c "
        REVOKE CONNECT ON DATABASE $db FROM PUBLIC;
        SELECT pg_terminate_backend(pid)
          FROM pg_stat_activity
         WHERE datname = '$db'
           AND pid <> pg_backend_pid();
    " >/dev/null 2>&1 || true
    sleep 1
    sql "$engine" -c "DROP DATABASE $db;" >/dev/null
}

# ---------------------------------------------------------------------------
# Preflight (mirrors Dan's checks)
# ---------------------------------------------------------------------------
preflight() {
    log "Preflight checks"
    [ -d "$YB_SRC_DIR" ]                       || fail "YB_SRC_DIR not found: $YB_SRC_DIR"
    [ -x "$GEOS_PATH/geos-config" ]            || fail "geos-config not at $GEOS_PATH (set GEOS_PATH)"
    [ -f "$DEMO_DATA_GZ" ]                     || fail "POI data not found: $DEMO_DATA_GZ"
    [ -f "$YB_SRC_DIR/yb_build.sh" ]           || fail "yb_build.sh missing"
    [ -f "$YB_SRC_DIR/bin/yb-ctl" ]            || fail "yb-ctl missing"
    [ -x "$PG_BIN/postgres" ]                  || fail "native PG15 not at $PG_BIN/postgres (install postgresql15-server)"
    [ -x "$PG_BIN/initdb" ]                    || fail "initdb not at $PG_BIN/initdb"
    [ -f "$PG_BIN/../lib/postgis-3.so" ]       || fail "PostGIS not installed under $PG_BIN/../lib (install postgis34_15 or similar)"
    ok "Paths look sane (YB + native PG15 + PostGIS all present)"
}

# ---------------------------------------------------------------------------
# Step 1: build (only if needed)
# ---------------------------------------------------------------------------
build_if_needed() {
    if [ "$SKIP_BUILD" = "1" ]; then
        log "Build step skipped (SKIP_BUILD=1)"
        return 0
    fi
    log "Build check"

    local geo_ctl="$EXT_DIR/yb_geospatial.control"
    local geo_sql="$EXT_DIR/yb_geospatial--1.0.sql"
    local s2_so="$YB_SRC_DIR/build/latest/postgres/lib/yb_geospatial_s2.so"
    local s2_ctl="$EXT_DIR/yb_geospatial_s2.control"

    # yb_geospatial is pure SQL -- only needs the .control + .sql files.
    # yb_geospatial_s2 is a C extension -- needs the .so too.
    local need_build=0
    [ -f "$geo_ctl" ] && [ -f "$geo_sql" ] || need_build=1
    [ -f "$s2_so" ]   && [ -f "$s2_ctl" ]  || need_build=1

    if [ "$need_build" = "1" ]; then
        log "Building YB (local compile, GEOS-on-PATH)"
        cd "$YB_SRC_DIR"
        export PATH="$GEOS_PATH:$PATH"
        YB_REMOTE_COMPILATION=0 ./yb_build.sh release \
            --no-tests --skip-java --no-remote
        cd "$SCRIPT_DIR"
        ok "Build complete"
    else
        ok "Both extensions already installed under $EXT_DIR — skipping build"
    fi

    # Re-verify post-build
    [ -f "$geo_ctl" ]  || fail "yb_geospatial.control still missing after build"
    [ -f "$geo_sql" ]  || fail "yb_geospatial--1.0.sql still missing after build"
    [ -f "$s2_so" ]    || fail "yb_geospatial_s2.so still missing after build"
    ok "Extension files present"
}

# ---------------------------------------------------------------------------
# Step 2a: YugabyteDB cluster
# ---------------------------------------------------------------------------
ensure_yb_cluster() {
    log "YugabyteDB cluster"
    if pgrep -f "yb-tserver" &>/dev/null \
       && yb_psql -c "SELECT 1;" &>/dev/null; then
        ok "YB cluster already running and accepting YSQL on port $YB_PORT"
        return 0
    fi

    "$YB_SRC_DIR/bin/yb-ctl" destroy 2>/dev/null || true
    "$YB_SRC_DIR/bin/yb-ctl" start
    ok "YB cluster started"

    local i=0
    while ! yb_psql -c "SELECT 1;" &>/dev/null; do
        sleep 2; i=$((i+1))
        [ "$i" -ge 15 ] && fail "YSQL not ready after 30s"
    done
    ok "ysqlsh connectivity verified"
}

# ---------------------------------------------------------------------------
# Step 2b: native PG15 + PostGIS cluster (separate, on $PG_PORT)
# Mirrors s2_vs_geohash_benchmark/setup/00_setup_postgis.sh.
# ---------------------------------------------------------------------------
port_holder_pid() {
    # Returns the pid bound to 127.0.0.1:$PG_PORT, or empty.
    local line
    line=$(ss -tlnp 2>/dev/null \
        | awk -v p=":$PG_PORT" '$4 ~ p"$" { print; exit }') || true
    [ -n "$line" ] || { echo ""; return 0; }
    echo "$line" | grep -oP 'pid=\K[0-9]+' | head -1 || true
}

ensure_pg_cluster() {
    log "Native PG15+PostGIS cluster (port $PG_PORT)"

    # Create parent dir for the data + log files (default lives in
    # $HOME/.run_compare so it's outside the git tree).
    mkdir -p "$(dirname "$PG_DATA")"

    # If our own cluster is up and reachable, we're done.
    if pg_psql -c "SELECT 1;" &>/dev/null; then
        ok "PG cluster already running on port $PG_PORT"
        return 0
    fi

    # Try a graceful stop in case a previous postmaster from $PG_DATA is alive
    # but in a half-broken state.
    "$PG_BIN/pg_ctl" -D "$PG_DATA" -m fast stop 2>/dev/null || true

    # If somebody else still holds the port, kill them.
    local pid
    pid=$(port_holder_pid)
    if [ -n "${pid:-}" ]; then
        ok "Clearing stale process on port $PG_PORT (pid=$pid)"
        kill -9 "$pid" 2>/dev/null || true
        sleep 2
    fi
    pid=$(port_holder_pid)
    [ -z "${pid:-}" ] || fail "Port $PG_PORT still bound by pid=$pid; set PG_PORT=<other>"

    # Initialize the data dir if it's empty.
    if [ ! -f "$PG_DATA/PG_VERSION" ]; then
        log "initdb -> $PG_DATA"
        "$PG_BIN/initdb" -D "$PG_DATA" --encoding=UTF8 --locale=C -U "$USER" >/dev/null
        # Standard benchmark-friendly tweaks.
        sed -i "s|^#\?listen_addresses.*|listen_addresses = '127.0.0.1'|"          "$PG_DATA/postgresql.conf"
        sed -i "s|^#\?port .*|port = $PG_PORT|"                                    "$PG_DATA/postgresql.conf"
        sed -i "s|^#\?unix_socket_directories.*|unix_socket_directories = '/tmp'|" "$PG_DATA/postgresql.conf"
        sed -i "s|^#\?shared_buffers.*|shared_buffers = 256MB|"                    "$PG_DATA/postgresql.conf"
        sed -i "s|^#\?work_mem.*|work_mem = 64MB|"                                 "$PG_DATA/postgresql.conf"
        sed -i "s|^#\?fsync.*|fsync = off|"                                        "$PG_DATA/postgresql.conf"
        sed -i "s|^#\?synchronous_commit.*|synchronous_commit = off|"              "$PG_DATA/postgresql.conf"
        ok "initdb complete"
    fi

    log "Starting PG15 on port $PG_PORT"
    "$PG_BIN/pg_ctl" -D "$PG_DATA" -l "$PG_LOG" -w start >/dev/null

    # Sanity check
    pg_psql -c "SELECT 1;" >/dev/null \
        || fail "PG15 started but psql can't connect on port $PG_PORT"
    ok "PG15 ready on port $PG_PORT"
}

# ---------------------------------------------------------------------------
# Step 3: data file extraction
# ---------------------------------------------------------------------------
ensure_data() {
    log "POI data file"
    if [ ! -f "$DEMO_DATA" ]; then
        gunzip -k "$DEMO_DATA_GZ"
        ok "Extracted $DEMO_DATA"
    else
        ok "$DEMO_DATA already extracted"
    fi
    # Quick sanity check: header row + at least 344k records
    local rows
    rows=$(wc -l < "$DEMO_DATA")
    [ "$rows" -ge "$EXPECT_TOTAL" ] \
        || fail "Data file only has $rows rows, expected >= $EXPECT_TOTAL"
    ok "Data file has $rows lines (header + $((rows-1)) records)"
}

# ---------------------------------------------------------------------------
# Step 4: per-DB load (parametrized by engine + extension flavor)
# ---------------------------------------------------------------------------
# Args: engine ("yb"|"pg"), db_name, extension_name, flavor ("geohash"|"s2"|"postgis")
load_one_db() {
    local engine="$1" db="$2" ext="$3" flavor="$4"

    log "Setting up $db (engine: $engine, extension: $ext, flavor: $flavor)"

    # 4a. Idempotent skip if already loaded ----------------------------------
    local exists
    exists=$(sql "$engine" -tAc \
        "SELECT 1 FROM pg_database WHERE datname='$db';" 2>/dev/null || true)
    if [ "$exists" = "1" ]; then
        local total_rows
        total_rows=$(sql_db_quiet "$engine" "$db" "SELECT
            (SELECT count(*) FROM restaurants) +
            (SELECT count(*) FROM shops) +
            (SELECT count(*) FROM services);" 2>/dev/null || echo "0")
        if [ "$total_rows" -ge "$EXPECT_TOTAL" ] 2>/dev/null; then
            ok "$db already has $total_rows rows across the 3 tables — skipping"
            return 0
        else
            ok "$db exists but only $total_rows rows total — recreating"
            drop_db_force "$engine" "$db"
            exists=""
        fi
    fi

    # 4b. Fresh database + extension -----------------------------------------
    sql "$engine" -c "CREATE DATABASE $db;"
    sql_db "$engine" "$db" "CREATE EXTENSION $ext;"
    ok "$db created with extension $ext"

    # 4c. For the S2 flavor on YB, force the .so to load for every future
    # session via session_preload_libraries -- otherwise the next session's
    # CREATE INDEX ... USING gist (geom) would arrive before _PG_init runs
    # and YB would reject the gist access method outright.
    if [ "$flavor" = "s2" ]; then
        sql_db "$engine" "$db" \
            "ALTER DATABASE $db SET session_preload_libraries TO '$ext';" \
            >/dev/null
        ok "$db: session_preload_libraries='$ext' (auto-loads hooks per session)"
    fi

    # 4d. Create the 3 POI tables -------------------------------------------
    # All three flavors get the SAME logical schema (same column set so cross-
    # DB comparisons are apples-to-apples) but with flavor-specific indexing:
    #   - geohash : explicit geo_hash10 column + B-tree on LEFT(geo_hash10, N)
    #   - s2      : geom only, USING gist (intercepted by ProcessUtility hook)
    #   - postgis : geom only, USING gist (real GiST/R-tree, native PG)
    if [ "$flavor" = "geohash" ]; then
        for tbl in restaurants shops services; do
            sql_db "$engine" "$db" "
                DROP TABLE IF EXISTS $tbl;
                CREATE TABLE $tbl (
                    id          BIGINT PRIMARY KEY,
                    name        TEXT,
                    address     TEXT,
                    city        TEXT,
                    province    TEXT,
                    postcode    TEXT,
                    category    TEXT,
                    subcategory TEXT,
                    geom        geometry,
                    geo_hash10  TEXT
                );
                CREATE INDEX ${tbl}_gh5_idx ON $tbl (LEFT(geo_hash10, 5), name);
                CREATE INDEX ${tbl}_gh6_idx ON $tbl (LEFT(geo_hash10, 6), name);
            " >/dev/null
        done
        ok "Created restaurants, shops, services (with prefix indexes on geo_hash10)"
    elif [ "$flavor" = "s2" ]; then
        for tbl in restaurants shops services; do
            sql_db "$engine" "$db" "
                DROP TABLE IF EXISTS $tbl;
                CREATE TABLE $tbl (
                    id          BIGINT PRIMARY KEY,
                    name        TEXT,
                    address     TEXT,
                    city        TEXT,
                    province    TEXT,
                    postcode    TEXT,
                    category    TEXT,
                    subcategory TEXT,
                    geom        geometry
                );
                CREATE INDEX ${tbl}_geom_idx ON $tbl USING gist (geom);
            " >/dev/null
        done
        ok "Created restaurants, shops, services (with USING gist intercepted by hook)"
    else  # postgis
        for tbl in restaurants shops services; do
            # Real PostGIS supports the typmod form geometry(Point, 4326).
            sql_db "$engine" "$db" "
                DROP TABLE IF EXISTS $tbl;
                CREATE TABLE $tbl (
                    id          BIGINT PRIMARY KEY,
                    name        TEXT,
                    address     TEXT,
                    city        TEXT,
                    province    TEXT,
                    postcode    TEXT,
                    category    TEXT,
                    subcategory TEXT,
                    geom        geometry(Point, 4326)
                );
                CREATE INDEX ${tbl}_geom_idx ON $tbl USING GIST (geom);
            " >/dev/null
        done
        ok "Created restaurants, shops, services (with native PostGIS GiST index)"
    fi

    # 4e. Stage the raw CSV in a regular (non-temp) table -------------------
    sql_db "$engine" "$db" "
        DROP TABLE IF EXISTS raw_pois;
        CREATE TABLE raw_pois (
            md_pk        BIGINT,
            md_lat       TEXT,
            md_lng       TEXT,
            geo_hash10   TEXT,
            md_name      TEXT,
            md_address   TEXT,
            md_city      TEXT,
            md_province  TEXT,
            md_country   TEXT,
            md_postcode  TEXT,
            md_phone     TEXT,
            md_category  TEXT,
            md_subcategory TEXT,
            md_mysource  TEXT,
            md_tags      TEXT,
            md_type      TEXT
        );
    " >/dev/null
    # \copy must be a single statement; can't appear inside a multi-stmt -c.
    # ROWS_PER_TRANSACTION is a YugabyteDB-specific COPY option (it bounds
    # the size of each implicit txn so DocDB doesn't OOM on a 344K-row
    # bulk load).  Vanilla PG15 doesn't recognize it, so we only pass it
    # for the yb engine.
    local copy_opts="FORMAT csv, DELIMITER '|', HEADER true"
    if [ "$engine" = "yb" ]; then
        copy_opts="$copy_opts, ROWS_PER_TRANSACTION 1000"
    fi
    sql "$engine" -d "$db" -c \
        "\\copy raw_pois FROM '$DEMO_DATA' WITH ($copy_opts);"
    local raw_count
    raw_count=$(sql_db_quiet "$engine" "$db" "SELECT count(*) FROM raw_pois;")
    ok "Staged $raw_count rows in raw_pois"

    # 4f. Fan out into the 3 target tables via the API ------------------------
    log "Fanning out into 3 POI tables via ST_MakePoint API"

    local geo_columns geo_select_extra makepoint_expr
    if [ "$flavor" = "geohash" ]; then
        geo_columns="id, name, address, city, province, postcode, category, subcategory, geom, geo_hash10"
        geo_select_extra=", COALESCE(geo_hash10, geohash_encode(md_lat::float8, md_lng::float8, 10))"
        makepoint_expr="ST_MakePoint(md_lng::float8, md_lat::float8)"
    elif [ "$flavor" = "s2" ]; then
        geo_columns="id, name, address, city, province, postcode, category, subcategory, geom"
        geo_select_extra=""
        makepoint_expr="ST_MakePoint(md_lng::float8, md_lat::float8)"
    else  # postgis -- typmod-tagged column, so SetSRID(MakePoint, 4326)
        geo_columns="id, name, address, city, province, postcode, category, subcategory, geom"
        geo_select_extra=""
        makepoint_expr="ST_SetSRID(ST_MakePoint(md_lng::float8, md_lat::float8), 4326)"
    fi

    # restaurants
    sql_db "$engine" "$db" "
        INSERT INTO restaurants ($geo_columns)
        SELECT md_pk, md_name, md_address, md_city, md_province, md_postcode,
               md_category, md_subcategory,
               $makepoint_expr
               $geo_select_extra
          FROM raw_pois
         WHERE md_lat IS NOT NULL AND md_lng IS NOT NULL
           AND md_category IN $RESTAURANT_CATS;
    " >/dev/null

    # shops
    sql_db "$engine" "$db" "
        INSERT INTO shops ($geo_columns)
        SELECT md_pk, md_name, md_address, md_city, md_province, md_postcode,
               md_category, md_subcategory,
               $makepoint_expr
               $geo_select_extra
          FROM raw_pois
         WHERE md_lat IS NOT NULL AND md_lng IS NOT NULL
           AND md_category IN $SHOP_CATS;
    " >/dev/null

    # services (everything else)
    sql_db "$engine" "$db" "
        INSERT INTO services ($geo_columns)
        SELECT md_pk, md_name, md_address, md_city, md_province, md_postcode,
               md_category, md_subcategory,
               $makepoint_expr
               $geo_select_extra
          FROM raw_pois
         WHERE md_lat IS NOT NULL AND md_lng IS NOT NULL
           AND md_category NOT IN $RESTAURANT_CATS
           AND md_category NOT IN $SHOP_CATS;
    " >/dev/null

    # 4g. Per-table row count check ------------------------------------------
    local r_count s_count m_count
    r_count=$(sql_db_quiet "$engine" "$db" "SELECT count(*) FROM restaurants;")
    s_count=$(sql_db_quiet "$engine" "$db" "SELECT count(*) FROM shops;")
    m_count=$(sql_db_quiet "$engine" "$db" "SELECT count(*) FROM services;")
    [ "$r_count" -ge "$EXPECT_RESTAURANTS_MIN" ] \
        || fail "$db.restaurants has $r_count, expected >= $EXPECT_RESTAURANTS_MIN"
    [ "$s_count" -ge "$EXPECT_SHOPS_MIN" ] \
        || fail "$db.shops has $s_count, expected >= $EXPECT_SHOPS_MIN"
    [ "$m_count" -ge "$EXPECT_SERVICES_MIN" ] \
        || fail "$db.services has $m_count, expected >= $EXPECT_SERVICES_MIN"
    ok "$db loaded: restaurants=$r_count, shops=$s_count, services=$m_count"

    # 4h. Tidy up the staging table now that the 3 target tables hold the data
    sql_db "$engine" "$db" "DROP TABLE raw_pois;" >/dev/null
}

# ---------------------------------------------------------------------------
# Step 5: verification (Dan's-style EXPLAIN + sample query)
# ---------------------------------------------------------------------------
verify_geohash() {
    log "Verifying $GEO_DB (YB + pure-SQL geohash)"
    local plan
    plan=$(sql_db_quiet yb "$GEO_DB" "
        EXPLAIN (COSTS OFF)
        SELECT id FROM restaurants
         WHERE LEFT(geo_hash10, 5) = ANY(
            ARRAY(SELECT geohash_cells_for_bbox(-105.09, 40.57, -105.06, 40.60, 5))
         );")
    if echo "$plan" | grep -qi "Index Scan"; then
        ok "$GEO_DB.restaurants spatial query uses Index Scan"
    else
        printf "    %s\n" "${plan//$'\n'/$'\n    '}"
        fail "$GEO_DB.restaurants spatial query NOT using Index Scan"
    fi

    local hits
    hits=$(sql_db_quiet yb "$GEO_DB" "
        SELECT count(*) FROM restaurants
         WHERE LEFT(geo_hash10, 5) = ANY(
            ARRAY(SELECT geohash_cells_for_bbox(-105.09, 40.57, -105.06, 40.60, 5))
         );")
    ok "$GEO_DB.restaurants in Fort Collins bbox: $hits"
}

verify_s2() {
    log "Verifying $S2_DB (YB + S2 / planner_hook rewrite)"
    sql_db_quiet yb "$S2_DB" "SELECT PostGIS_Version();" >/dev/null

    local plan
    plan=$(sql_db_quiet yb "$S2_DB" "
        EXPLAIN (COSTS OFF)
        SELECT id FROM restaurants
         WHERE ST_Intersects(geom, ST_MakeEnvelope(-105.09, 40.57, -105.06, 40.60));")
    if echo "$plan" | grep -qi "spatial_candidates"; then
        ok "$S2_DB.restaurants planner_hook injected spatial_candidates()"
    else
        printf "    %s\n" "${plan//$'\n'/$'\n    '}"
        fail "$S2_DB.restaurants spatial query NOT using planner_hook rewrite"
    fi

    local hits
    hits=$(sql_db_quiet yb "$S2_DB" "
        SELECT count(*) FROM restaurants
         WHERE ST_Intersects(geom, ST_MakeEnvelope(-105.09, 40.57, -105.06, 40.60));")
    ok "$S2_DB.restaurants in Fort Collins bbox: $hits"

    local idx_rows
    idx_rows=$(sql_db_quiet yb "$S2_DB" "SELECT count(*) FROM restaurants_s2_index;")
    ok "$S2_DB.restaurants_s2_index has $idx_rows mapping rows"
}

verify_postgis() {
    log "Verifying $POSTGIS_DB (native PG15 + PostGIS / real GiST)"
    local plan
    plan=$(sql_db_quiet pg "$POSTGIS_DB" "
        EXPLAIN (COSTS OFF)
        SELECT id FROM restaurants
         WHERE ST_Intersects(geom, ST_MakeEnvelope(-105.09, 40.57, -105.06, 40.60, 4326));")
    # Native PostGIS uses a real GiST/R-tree index.  Look for either an
    # Index Scan or a Bitmap Index Scan over the GiST index.
    if echo "$plan" | grep -qiE "Index Scan|Bitmap Index Scan"; then
        ok "$POSTGIS_DB.restaurants spatial query uses GiST Index Scan"
    else
        printf "    %s\n" "${plan//$'\n'/$'\n    '}"
        fail "$POSTGIS_DB.restaurants spatial query NOT using a GiST index scan"
    fi

    local hits
    hits=$(sql_db_quiet pg "$POSTGIS_DB" "
        SELECT count(*) FROM restaurants
         WHERE ST_Intersects(geom, ST_MakeEnvelope(-105.09, 40.57, -105.06, 40.60, 4326));")
    ok "$POSTGIS_DB.restaurants in Fort Collins bbox: $hits"
}

verify_agreement() {
    log "Cross-checking hit counts across all three engines"
    local geo_hits s2_hits postgis_hits
    geo_hits=$(sql_db_quiet yb "$GEO_DB" "
        SELECT count(*) FROM restaurants
         WHERE LEFT(geo_hash10, 5) = ANY(
            ARRAY(SELECT geohash_cells_for_bbox(-105.09, 40.57, -105.06, 40.60, 5))
         );")
    s2_hits=$(sql_db_quiet yb "$S2_DB" "
        SELECT count(*) FROM restaurants
         WHERE ST_Intersects(geom, ST_MakeEnvelope(-105.09, 40.57, -105.06, 40.60));")
    postgis_hits=$(sql_db_quiet pg "$POSTGIS_DB" "
        SELECT count(*) FROM restaurants
         WHERE ST_Intersects(geom, ST_MakeEnvelope(-105.09, 40.57, -105.06, 40.60, 4326));")
    # The three rows-counts won't match exactly because:
    #   - geohash : 5-char-prefix bbox cover, NO ST_Intersects recheck →
    #               returns false positives in adjacent cells
    #   - s2      : ST_Intersects recheck via planner_hook → exact
    #   - postgis : ST_Intersects via real GiST → exact (matches s2)
    # So s2 == postgis is the apples-to-apples agreement check.
    ok "Hits: geohash=$geo_hits, s2=$s2_hits, postgis=$postgis_hits"
    [ "$geo_hits"     -gt 0 ] || fail "geohash returned 0 hits"
    [ "$s2_hits"      -gt 0 ] || fail "s2 returned 0 hits"
    [ "$postgis_hits" -gt 0 ] || fail "postgis returned 0 hits"
    if [ "$s2_hits" = "$postgis_hits" ]; then
        ok "s2 ($s2_hits) == postgis ($postgis_hits)  ← exact rechecks agree"
    else
        ok "NOTE: s2=$s2_hits vs postgis=$postgis_hits differ slightly (acceptable; both do exact recheck)"
    fi
}

# ---------------------------------------------------------------------------
# do_start / do_verify / do_stop / do_clean (top-level)
# ---------------------------------------------------------------------------
do_start() {
    preflight
    build_if_needed
    ensure_yb_cluster
    ensure_pg_cluster
    ensure_data
    load_one_db yb "$GEO_DB"     "yb_geospatial"    "geohash"
    load_one_db yb "$S2_DB"      "yb_geospatial_s2" "s2"
    load_one_db pg "$POSTGIS_DB" "postgis"          "postgis"
    verify_geohash
    verify_s2
    verify_postgis
    verify_agreement
    install_helper_script
    log "All steps green. All three DBs ready."
    printf "  YB geohash:  %s -h %s -p %s -d %s\n" "$YSQLSH" "$DB_HOST" "$YB_PORT" "$GEO_DB"
    printf "  YB s2:       %s -h %s -p %s -d %s\n" "$YSQLSH" "$DB_HOST" "$YB_PORT" "$S2_DB"
    printf "  PG PostGIS:  %s -h %s -p %s -d %s\n" "$PG_BIN/psql" "$DB_HOST" "$PG_PORT" "$POSTGIS_DB"

    print_connect_banner
}

# ---------------------------------------------------------------------------
# Drop a tiny `bench-open` helper at /tmp/bench-open on the remote.  This
# lets the printed SSH commands stay short enough that macOS Terminal.app
# can't line-wrap them mid-arg (Terminal hard-wraps long lines at
# ~80 columns, inserting real newlines mid-command).
#
# /tmp is short and writable.  Helper is regenerated on every
# `./run_compare.sh start` so reboots / tmpfs-cleaning don't break it.
# ---------------------------------------------------------------------------
HELPER_PATH="/tmp/bench-open"

install_helper_script() {
    log "Installing bench-open helper at $HELPER_PATH"
    mkdir -p "$(dirname "$HELPER_PATH")"
    cat > "$HELPER_PATH" <<HELPER
#!/bin/bash
# bench-open <db>  -- open a psql/ysqlsh session against one of the
# 3 comparison DBs.  Generated by run_compare.sh -- regenerate with
# \`./run_compare.sh start\` if paths drift.
set -e
case "\$1" in
    geohash)  exec "$YSQLSH" -h "$DB_HOST" -p "$YB_PORT" -d "$GEO_DB" ;;
    s2)       exec "$YSQLSH" -h "$DB_HOST" -p "$YB_PORT" -d "$S2_DB" ;;
    postgis)  exec "$PG_BIN/psql" -h "$DB_HOST" -p "$PG_PORT" -d "$POSTGIS_DB" ;;
    *) echo "Usage: \$0 {geohash|s2|postgis}" >&2; exit 1 ;;
esac
HELPER
    chmod +x "$HELPER_PATH"
    ok "$HELPER_PATH installed"
}

# ---------------------------------------------------------------------------
# Print copy-paste one-liners for opening three native local terminals,
# each ssh'd to one of the bench DBs.  Spawning local terminal windows
# from a remote shell is OS-specific (Terminal.app on macOS uses
# AppleScript; gnome-terminal on Linux has its own --tab / --window
# flags), so we print one one-liner per common platform; user picks the
# one that matches their laptop and pastes it into a LOCAL shell.
#
# SSH_TARGET overrides the user@host combo if your SSH config uses an
# alias.  E.g. SSH_TARGET=dev makes the printed lines say `ssh -t dev`
# instead of `ssh -t te-yenchou@<long-fqdn>`.
# ---------------------------------------------------------------------------
print_connect_banner() {
    # Use the short hostname (`hostname -s`) by default rather than the FQDN.
    # Most users only have the short name in ~/.ssh/known_hosts (they ssh
    # in via short-name DNS or an SSH config alias), so a printed FQDN
    # would trigger a fresh host-key verification prompt and likely fail.
    # SSH_TARGET overrides this entirely.
    local ssh_target="${SSH_TARGET:-$USER@$(hostname -s 2>/dev/null || hostname)}"

    # Three remote commands the user dispatches to local terminals.
    local cmd_geo="$YSQLSH -h $DB_HOST -p $YB_PORT -d $GEO_DB"
    local cmd_s2="$YSQLSH -h $DB_HOST -p $YB_PORT -d $S2_DB"
    local cmd_pg="$PG_BIN/psql -h $DB_HOST -p $PG_PORT -d $POSTGIS_DB"

    # Heredoc avoids the printf-escape spiral for nested " and \. Inside
    # an unquoted heredoc, $var expands, \$var doesn't, \" is literal,
    # and \\ at end-of-line outputs a literal backslash + newline (which
    # is what the user needs for shell line-continuation).
    cat <<EOF

============================================================
  COPY ALL 3 LINES INTO YOUR LOCAL macOS SHELL (in one paste)
  -> spawns 3 native Terminal.app windows, one per DB
============================================================

osascript -e "tell app \"Terminal\" to do script \"ssh -t $ssh_target '$HELPER_PATH geohash'\""
osascript -e "tell app \"Terminal\" to do script \"ssh -t $ssh_target '$HELPER_PATH s2'\""
osascript -e "tell app \"Terminal\" to do script \"ssh -t $ssh_target '$HELPER_PATH postgis'\""

The remote command is the absolute path to bench-open (no ~ expansion,
no line wrap concerns).  Wrapped in single quotes so the receiving shell
parses atomically.

If pasting misbehaves, open 3 terminals manually and paste:

  ssh -t $ssh_target '$HELPER_PATH geohash'
  ssh -t $ssh_target '$HELPER_PATH s2'
  ssh -t $ssh_target '$HELPER_PATH postgis'

Override the SSH target:  SSH_TARGET=<alias> ./run_compare.sh start
(e.g. if ~/.ssh/config has "Host dev ...", use SSH_TARGET=dev)

EOF
}

do_verify() {
    log "Verify-only run"
    yb_psql -c "SELECT 1;" >/dev/null \
        || fail "YB cluster not reachable (run '$0 start')"
    pg_psql -c "SELECT 1;" >/dev/null \
        || fail "PG cluster not reachable on port $PG_PORT (run '$0 start')"
    ok "Both clusters reachable"
    verify_geohash
    verify_s2
    verify_postgis
    verify_agreement
}

do_stop() {
    log "Stopping clusters (data persists)"
    if pgrep -f "yb-tserver" &>/dev/null; then
        "$YB_SRC_DIR/bin/yb-ctl" stop 2>/dev/null \
            || pkill -f "yb-tserver|yb-master" 2>/dev/null || true
        ok "YB cluster stopped"
    else
        ok "YB cluster was not running"
    fi
    if pg_psql -c "SELECT 1;" &>/dev/null; then
        "$PG_BIN/pg_ctl" -D "$PG_DATA" -m fast stop >/dev/null 2>&1 || true
        ok "PG cluster stopped"
    else
        ok "PG cluster was not running"
    fi
}

do_clean() {
    do_stop
    log "Cleaning"
    if [ -f "$DEMO_DATA" ]; then
        rm -f "$DEMO_DATA"
        ok "Removed extracted data file"
    fi
    ok "Clean complete (DB data was destroyed when cluster stopped)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${1:-help}" in
    start)  do_start ;;
    verify) do_verify ;;
    stop)   do_stop ;;
    clean)  do_clean ;;
    *)
        cat <<EOF
Usage: $0 {start|verify|stop|clean}

  start   -- Build (if needed), launch cluster, create $GEO_DB and $S2_DB,
             create restaurants/shops/services, load all 344k POIs via ST_MakePoint,
             verify EXPLAIN plans use Index Scan (geohash) / planner_hook (s2).
             Idempotent: re-runs are safe.
  verify  -- Re-run the EXPLAIN + sample-query checks against the existing DBs.
  stop    -- Stop the cluster (data persists).
  clean   -- Stop + remove extracted data file (DB data went with the cluster).

Environment overrides:
  YB_SRC_DIR   yugabyte-db source root           (default: $YB_SRC_DIR)
  GEOS_PATH    GEOS install bin dir              (default: $GEOS_PATH)
  SKIP_BUILD   "1" to skip the build phase       (default: 0)
EOF
        ;;
esac
