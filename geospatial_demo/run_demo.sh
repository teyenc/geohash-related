#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Configurable paths (override via environment variables)
# ---------------------------------------------------------------------------
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
YB_SRC_DIR="${YB_SRC_DIR:-$REPO_DIR/../yugabyte-db}"
GEOSERVER_HOME="${GEOSERVER_HOME:-$HOME/geoserver}"
JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/zulu-17.jdk}"

DEMO_DIR="$SCRIPT_DIR"
DATA_DIR="$DEMO_DIR/data"
DATA_FILE="$DATA_DIR/19_mapData.pipe"
DATA_GZ="$DATA_DIR/19_mapData.pipe.gz"

DB_HOST="127.0.0.1"
DB_PORT="5433"
DB_NAME="geospatial_test"
DB_USER="yugabyte"
FLASK_PORT="5011"
GS_PORT="8080"

YSQLSH="$YB_SRC_DIR/build/latest/postgres/bin/ysqlsh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf "\n=== %s ===\n" "$*"; }
ok()   { printf "  [OK]  %s\n" "$*"; }
fail() { printf "  [FAIL] %s\n" "$*"; return 1; }
wait_for_port() {
    local port=$1 label=$2 max=${3:-30}
    local i=0
    while ! curl -s -o /dev/null -w '' "http://localhost:$port/" 2>/dev/null; do
        sleep 1; i=$((i+1))
        if [ "$i" -ge "$max" ]; then fail "$label not ready after ${max}s"; return 1; fi
    done
    ok "$label is up (port $port)"
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
preflight() {
    log "Preflight checks"
    [ -x "$YSQLSH" ]                       || fail "ysqlsh not found at $YSQLSH — set YB_SRC_DIR"
    [ -f "$YB_SRC_DIR/bin/yb-ctl" ]        || fail "yb-ctl not found — set YB_SRC_DIR"
    [ -f "$GEOSERVER_HOME/start.jar" ]     || fail "GeoServer not found — set GEOSERVER_HOME"
    [ -x "$JAVA_HOME/bin/java" ]           || fail "Java not found — set JAVA_HOME"
    [ -f "$DATA_GZ" ]                      || fail "Data file not found: $DATA_GZ"
    python3 -c "import flask" 2>/dev/null  || fail "flask not installed (pip3 install flask)"
    python3 -c "import psycopg2" 2>/dev/null || fail "psycopg2 not installed (pip3 install psycopg2-binary)"
    ok "All prerequisites satisfied"
}

# ---------------------------------------------------------------------------
# stop
# ---------------------------------------------------------------------------
do_stop() {
    log "Stopping services"

    if pkill -f "python3 60_index.py" 2>/dev/null; then ok "Flask stopped"
    else ok "Flask was not running"; fi

    if pkill -f "start.jar" 2>/dev/null; then ok "GeoServer stopped"
    else ok "GeoServer was not running"; fi

    if pgrep -f "yb-tserver" &>/dev/null; then
        "$YB_SRC_DIR/bin/yb-ctl" stop 2>/dev/null || pkill -f "yb-tserver|yb-master" 2>/dev/null || true
        ok "YugabyteDB stopped"
    else
        ok "YugabyteDB was not running"
    fi
}

# ---------------------------------------------------------------------------
# clean  (stop + drop data)
# ---------------------------------------------------------------------------
do_clean() {
    do_stop

    log "Cleaning data"
    if [ -f "$DATA_FILE" ]; then
        rm -f "$DATA_FILE"
        ok "Removed extracted data file"
    else
        ok "No extracted data file to remove"
    fi
    ok "Clean complete (database removed when cluster was destroyed)"
}

# ---------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------
do_start() {
    preflight

    # -- 1. YugabyteDB cluster ------------------------------------------------
    log "Starting YugabyteDB cluster"
    if pgrep -f "yb-tserver" &>/dev/null && $YSQLSH -h $DB_HOST -p $DB_PORT -c "SELECT 1;" &>/dev/null; then
        ok "Cluster already running"
    else
        "$YB_SRC_DIR/bin/yb-ctl" destroy 2>/dev/null || true
        "$YB_SRC_DIR/bin/yb-ctl" start
        ok "Cluster started"
    fi

    log "Waiting for YSQL to accept connections"
    local retries=0
    while ! $YSQLSH -h $DB_HOST -p $DB_PORT -c "SELECT 1;" &>/dev/null; do
        sleep 2; retries=$((retries+1))
        if [ "$retries" -ge 15 ]; then fail "YSQL not ready after 30s"; return 1; fi
    done
    ok "ysqlsh connectivity verified"

    # -- 2. Create database + extension ----------------------------------------
    log "Setting up database"
    local db_exists
    db_exists=$($YSQLSH -h $DB_HOST -p $DB_PORT -tAc \
        "SELECT 1 FROM pg_database WHERE datname='$DB_NAME';" 2>/dev/null || true)

    if [ "$db_exists" = "1" ]; then
        local row_count
        row_count=$($YSQLSH -h $DB_HOST -p $DB_PORT -d $DB_NAME -tAc \
            "SELECT count(*) FROM my_mapdata;" 2>/dev/null || echo "0")
        if [ "$row_count" -ge 344000 ]; then
            ok "Database '$DB_NAME' exists with $row_count rows — skipping load"
        else
            ok "Database exists but only $row_count rows — reloading"
            $YSQLSH -h $DB_HOST -p $DB_PORT -c "DROP DATABASE $DB_NAME;"
            db_exists=""
        fi
    fi

    if [ "$db_exists" != "1" ]; then
        $YSQLSH -h $DB_HOST -p $DB_PORT -c "CREATE DATABASE $DB_NAME;"
        $YSQLSH -h $DB_HOST -p $DB_PORT -d $DB_NAME -c "CREATE EXTENSION yb_geospatial;"
        ok "Database and extension created"

        # Extract data
        if [ ! -f "$DATA_FILE" ]; then
            gunzip -k "$DATA_GZ"
            ok "Data extracted"
        fi

        # Load data
        log "Loading 344K records (this takes ~45s)"
        $YSQLSH -h $DB_HOST -p $DB_PORT -d $DB_NAME -c \
            "\\copy my_mapdata(md_pk, md_lat, md_lng, geo_hash10, md_name, md_address, md_city, md_province, md_country, md_postcode, md_phone, md_category, md_subcategory, md_mysource, md_tags, md_type) FROM '$DATA_FILE' WITH (FORMAT csv, DELIMITER '|', HEADER true, ROWS_PER_TRANSACTION 100);"
        ok "Data loaded"

        # Backfill geometry
        log "Backfilling geometry column (~13s)"
        $YSQLSH -h $DB_HOST -p $DB_PORT -d $DB_NAME -c "
            UPDATE my_mapdata
            SET geom = ST_MakePoint(md_lng::double precision, md_lat::double precision)
            WHERE md_lat IS NOT NULL AND md_lng IS NOT NULL;"
        ok "Geometry backfilled"

        # Backfill geo_hash8
        log "Backfilling geo_hash8 column (~22s)"
        $YSQLSH -h $DB_HOST -p $DB_PORT -d $DB_NAME -c "
            UPDATE my_mapdata
            SET geo_hash8 = LEFT(geo_hash10, 8)
            WHERE geo_hash10 IS NOT NULL
              AND (geo_hash8 IS NULL OR geo_hash8 <> LEFT(geo_hash10, 8));"
        ok "geo_hash8 backfilled"

        local final_count
        final_count=$($YSQLSH -h $DB_HOST -p $DB_PORT -d $DB_NAME -tAc "SELECT count(*) FROM my_mapdata;")
        ok "Loaded $final_count rows"
    fi

    # -- 3. GeoServer ----------------------------------------------------------
    log "Starting GeoServer"
    if curl -s -o /dev/null -w '' "http://localhost:$GS_PORT/geoserver/web/" 2>/dev/null; then
        ok "GeoServer already running"
    else
        export JAVA_HOME
        export GEOSERVER_HOME
        cd "$GEOSERVER_HOME"
        nohup "$JAVA_HOME/bin/java" -DENABLE_JSONP=true -jar start.jar \
            > "$GEOSERVER_HOME/geoserver.log" 2>&1 &
        cd "$SCRIPT_DIR"
        log "Waiting for GeoServer to start (~20s)"
        wait_for_port "$GS_PORT" "GeoServer" 40
    fi

    # -- 4. Configure GeoServer ------------------------------------------------
    log "Configuring GeoServer"

    local ws_status
    ws_status=$(curl -s -o /dev/null -w "%{http_code}" \
        -u admin:geoserver \
        "http://localhost:$GS_PORT/geoserver/rest/workspaces/yugabyte.json")

    if [ "$ws_status" = "200" ]; then
        ok "Workspace 'yugabyte' already exists — skipping configuration"
    else
        curl -s -u admin:geoserver -X POST \
            "http://localhost:$GS_PORT/geoserver/rest/workspaces" \
            -H "Content-Type: application/json" \
            -d '{"workspace":{"name":"yugabyte"}}' >/dev/null
        ok "Workspace created"

        curl -s -u admin:geoserver -X POST \
            "http://localhost:$GS_PORT/geoserver/rest/workspaces/yugabyte/datastores" \
            -H "Content-Type: application/json" \
            -d '{
            "dataStore": {
                "name": "geospatial_test",
                "type": "PostGIS",
                "connectionParameters": {
                    "entry": [
                        {"@key":"host","$":"'"$DB_HOST"'"},
                        {"@key":"port","$":"'"$DB_PORT"'"},
                        {"@key":"database","$":"'"$DB_NAME"'"},
                        {"@key":"schema","$":"public"},
                        {"@key":"user","$":"'"$DB_USER"'"},
                        {"@key":"passwd","$":""},
                        {"@key":"dbtype","$":"postgis"},
                        {"@key":"Expose primary keys","$":"true"},
                        {"@key":"Estimated extends","$":"true"},
                        {"@key":"Encode functions","$":"true"},
                        {"@key":"Loose bbox","$":"true"},
                        {"@key":"preparedStatements","$":"false"}
                    ]
                }
            }
        }' >/dev/null
        ok "Data store created"

        curl -s -u admin:geoserver -X POST \
            "http://localhost:$GS_PORT/geoserver/rest/workspaces/yugabyte/datastores/geospatial_test/featuretypes" \
            -H "Content-Type: application/json" \
            -d '{
            "featureType": {
                "name": "my_mapdata_fast",
                "nativeName": "my_mapdata_fast",
                "title": "my_mapdata_fast",
                "srs": "EPSG:4326",
                "metadata": {
                    "entry": [{
                        "@key": "JDBC_VIRTUAL_TABLE",
                        "virtualTable": {
                            "name": "my_mapdata_fast",
                            "sql": "SELECT md_pk, md_name, md_address, md_city, md_province, md_postcode, md_category, md_subcategory, geom FROM my_mapdata WHERE LEFT(geo_hash10, 5) = ANY(ARRAY(SELECT geohash_cells_for_bbox(cast(%LON_MIN% as numeric), cast(%LAT_MIN% as numeric), cast(%LON_MAX% as numeric), cast(%LAT_MAX% as numeric), 5)))",
                            "escapeSql": false,
                            "keyColumn": "md_pk",
                            "geometry": {"name":"geom","type":"Point","srid":4326},
                            "parameter": [
                                {"name":"LON_MIN","defaultValue":"-105.09","regexpValidator":"^-?[\\d.]+$"},
                                {"name":"LAT_MIN","defaultValue":"40.57","regexpValidator":"^-?[\\d.]+$"},
                                {"name":"LON_MAX","defaultValue":"-105.06","regexpValidator":"^-?[\\d.]+$"},
                                {"name":"LAT_MAX","defaultValue":"40.60","regexpValidator":"^-?[\\d.]+$"}
                            ]
                        }
                    }]
                }
            }
        }' >/dev/null
        ok "SQL View layer created"
    fi

    # -- 5. Flask app ----------------------------------------------------------
    log "Starting Flask demo app"
    if curl -s -o /dev/null -w '' "http://localhost:$FLASK_PORT/" 2>/dev/null; then
        ok "Flask already running on port $FLASK_PORT"
    else
        cd "$DEMO_DIR/demo"
        nohup python3 60_index.py > "$DEMO_DIR/demo/flask.log" 2>&1 &
        cd "$SCRIPT_DIR"
        wait_for_port "$FLASK_PORT" "Flask" 10
    fi

    log "Demo is running"
    printf "  Flask app:     http://localhost:%s/\n" "$FLASK_PORT"
    printf "  GeoServer UI:  http://localhost:%s/geoserver/web/\n" "$GS_PORT"
    printf "  (Forward ports %s and %s if using SSH/Cursor Remote)\n" "$FLASK_PORT" "$GS_PORT"
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------
do_verify() {
    log "Verifying demo components"
    local errors=0

    # YugabyteDB
    if $YSQLSH -h $DB_HOST -p $DB_PORT -c "SELECT 1;" &>/dev/null; then
        ok "YugabyteDB is reachable"
    else
        fail "YugabyteDB is not reachable"; errors=$((errors+1))
    fi

    # Database + row count
    local row_count
    row_count=$($YSQLSH -h $DB_HOST -p $DB_PORT -d $DB_NAME -tAc \
        "SELECT count(*) FROM my_mapdata;" 2>/dev/null || echo "0")
    row_count=$(echo "$row_count" | tr -d ' ')
    if [ "$row_count" -ge 344000 ] 2>/dev/null; then
        ok "my_mapdata has $row_count rows"
    else
        fail "my_mapdata has $row_count rows (expected ~344688)"; errors=$((errors+1))
    fi

    # Geohash index scan
    local plan
    plan=$($YSQLSH -h $DB_HOST -p $DB_PORT -d $DB_NAME -tAc "
        EXPLAIN (COSTS OFF)
        SELECT md_pk FROM my_mapdata
        WHERE LEFT(geo_hash10, 5) = ANY(
            ARRAY(SELECT geohash_cells_for_bbox(-105.09, 40.57, -105.06, 40.60, 5))
        );" 2>/dev/null || true)
    if echo "$plan" | grep -qi "Index Scan"; then
        ok "Geohash query uses Index Scan"
    else
        fail "Geohash query NOT using Index Scan"; errors=$((errors+1))
    fi

    # GeoServer
    local gs_code
    gs_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$GS_PORT/geoserver/web/" 2>/dev/null || echo "000")
    if [ "$gs_code" = "200" ] || [ "$gs_code" = "302" ]; then
        ok "GeoServer is responding (HTTP $gs_code)"
    else
        fail "GeoServer not responding (HTTP $gs_code)"; errors=$((errors+1))
    fi

    # GeoServer → YB end-to-end
    local wfs_features
    local wfs_url="http://localhost:${GS_PORT}/geoserver/yugabyte/wfs?service=WFS&version=1.0.0&request=GetFeature&typeName=yugabyte:my_mapdata_fast&outputFormat=application/json&maxFeatures=3&viewparams=LON_MIN:-105.09%3BLAT_MIN:40.57%3BLON_MAX:-105.06%3BLAT_MAX:40.60"
    wfs_features=$(curl -s "$wfs_url" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('features',[])))" 2>/dev/null || echo "0")
    if [ "$wfs_features" -gt 0 ] 2>/dev/null; then
        ok "GeoServer WFS returns $wfs_features features (end-to-end OK)"
    else
        fail "GeoServer WFS returned no features"; errors=$((errors+1))
    fi

    # Flask
    local flask_code
    flask_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$FLASK_PORT/" 2>/dev/null || echo "000")
    if [ "$flask_code" = "200" ]; then
        ok "Flask app is responding (HTTP $flask_code)"
    else
        fail "Flask app not responding (HTTP $flask_code)"; errors=$((errors+1))
    fi

    echo ""
    if [ "$errors" -eq 0 ]; then
        log "All checks passed"
    else
        log "$errors check(s) FAILED"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${1:-help}" in
    start)  do_start ;;
    stop)   do_stop ;;
    clean)  do_clean ;;
    verify) do_verify ;;
    *)
        echo "Usage: $0 {start|stop|clean|verify}"
        echo ""
        echo "  start   — Start YB cluster, load data, start GeoServer + Flask"
        echo "  stop    — Stop Flask, GeoServer, and YB cluster"
        echo "  clean   — Stop everything and remove extracted data"
        echo "  verify  — Check all components are running correctly"
        echo ""
        echo "Environment overrides:"
        echo "  YB_SRC_DIR      Path to yugabyte-db source (default: ../yugabyte-db)"
        echo "  GEOSERVER_HOME  Path to GeoServer install  (default: ~/geoserver)"
        echo "  JAVA_HOME       Path to Java 17+ JDK       (default: /usr/lib/jvm/zulu-17.jdk)"
        ;;
esac
