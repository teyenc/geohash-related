# yb_geospatial — Reproduction Guide

End-to-end instructions for building, testing, and demoing the `yb_geospatial`
extension on YugabyteDB. Everything here runs from the `geohash-related/` folder
and the `yugabyte-db/` repo — no dependency on the upstream `geospatial_v05/`
repo.

## Directory Layout

```
code/
├── yugabyte-db/                         # YugabyteDB source (contains the extension)
│   └── src/postgres/yb-extensions/
│       └── yb_geospatial/
│           ├── yb_geospatial--1.0.sql   # Extension SQL (160+ functions, types, etc.)
│           ├── yb_geospatial.control
│           ├── Makefile
│           ├── sql/yb_geospatial.sql    # Regression test
│           └── expected/yb_geospatial.out
│
└── geohash-related/                     # This repo (independent of geospatial_v05)
    ├── README.md                        # This file
    └── geospatial_demo/
        ├── run_demo.sh                  # One-command start/stop/clean/verify
        ├── data/
        │   └── 19_mapData.pipe.gz       # 344K Colorado POI records (compressed)
        └── demo/
            ├── 60_index.py              # Flask demo app
            ├── properties.ini           # DB connection config
            ├── libraries/               # Python helper modules
            ├── static/                  # CSS, JS, logo
            ├── views/                   # HTML template (Leaflet map)
            └── slides/                  # Presentation images
```

---

## Quick Start (automated)

After building YugabyteDB (Part 1) and installing GeoServer (Part 6), the
`run_demo.sh` script handles everything else — cluster, database, data load,
GeoServer configuration, and the Flask app:

```bash
cd geospatial_demo
./run_demo.sh start    # start everything
./run_demo.sh verify   # check all components
./run_demo.sh stop     # stop all services
./run_demo.sh clean    # stop + remove extracted data
```

The script auto-discovers `yugabyte-db` as a sibling directory. Override paths
via environment variables if your layout differs:

```bash
YB_SRC_DIR=/path/to/yugabyte-db  GEOSERVER_HOME=/path/to/geoserver  ./run_demo.sh start
```

The step-by-step instructions below explain each phase in detail.

---

## Part 1: Build YugabyteDB with the Extension

```bash
cd yugabyte-db
./yb_build.sh release
```

The extension is a pure SQL extension (no C code), so it gets installed
automatically as part of the postgres build. Verify:

```bash
ls build/latest/postgres/share/extension/ | grep yb_geospatial
# Expected:
#   yb_geospatial--1.0.sql
#   yb_geospatial.control
```

---

## Part 2: Start the Cluster

```bash
cd yugabyte-db
bin/yb-ctl destroy   # if a cluster was already running
bin/yb-ctl start
```

Verify connectivity:

```bash
build/latest/postgres/bin/ysqlsh -h 127.0.0.1 -p 5433 -c "SELECT 1;"
```

---

## Part 3: Run the Regression Test (no data needed)

Create a fresh database and run the test:

```bash
YSQLSH="yugabyte-db/build/latest/postgres/bin/ysqlsh -h 127.0.0.1 -p 5433"

$YSQLSH -c "DROP DATABASE IF EXISTS regress_test;"
$YSQLSH -c "CREATE DATABASE regress_test;"
$YSQLSH -d regress_test \
  -f yugabyte-db/src/postgres/yb-extensions/yb_geospatial/sql/yb_geospatial.sql
```

All tests use inline data — no external files needed. To diff against expected
output:

```bash
$YSQLSH -d regress_test \
  -f yugabyte-db/src/postgres/yb-extensions/yb_geospatial/sql/yb_geospatial.sql \
  > /tmp/actual.out 2>&1

diff yugabyte-db/src/postgres/yb-extensions/yb_geospatial/expected/yb_geospatial.out \
     /tmp/actual.out
```

Note: the diff will show format differences (the expected file includes echoed
SQL from pg_regress, ysqlsh does not). The result values will match.

---

## Part 4: Load the 344K Dataset

Create a database for the full demo and install the extension:

```bash
YSQLSH="yugabyte-db/build/latest/postgres/bin/ysqlsh -h 127.0.0.1 -p 5433"

$YSQLSH -c "DROP DATABASE IF EXISTS geospatial_test;"
$YSQLSH -c "CREATE DATABASE geospatial_test;"
$YSQLSH -d geospatial_test -c "CREATE EXTENSION yb_geospatial;"
```

Extract and load the data:

```bash
cd geospatial_demo/data
gunzip -k 19_mapData.pipe.gz     # keeps the .gz, creates 19_mapData.pipe
cd ../..

$YSQLSH -d geospatial_test -c "\copy my_mapdata(md_pk, md_lat, md_lng, geo_hash10, md_name, md_address, md_city, md_province, md_country, md_postcode, md_phone, md_category, md_subcategory, md_mysource, md_tags, md_type) FROM 'geospatial_demo/data/19_mapData.pipe' WITH (FORMAT csv, DELIMITER '|', HEADER true, ROWS_PER_TRANSACTION 100);"
# Expected: COPY 344688 (~45 seconds)
```

Backfill the geometry column and geo_hash8:

```bash
$YSQLSH -d geospatial_test -c "
UPDATE my_mapdata
SET geom = ST_MakePoint(md_lng::double precision, md_lat::double precision)
WHERE md_lat IS NOT NULL AND md_lng IS NOT NULL;"
# Expected: UPDATE 344688 (~13 seconds)

$YSQLSH -d geospatial_test -c "
UPDATE my_mapdata
SET geo_hash8 = LEFT(geo_hash10, 8)
WHERE geo_hash10 IS NOT NULL
  AND (geo_hash8 IS NULL OR geo_hash8 <> LEFT(geo_hash10, 8));"
# Expected: UPDATE 344688 (~22 seconds)
```

Verify:

```bash
$YSQLSH -d geospatial_test -c "SELECT count(*) FROM my_mapdata;"
# Expected: 344688
```

---

## Part 5: Test the Two-Phase Geohash Query

This is the core performance pattern — it should produce an **Index Scan**,
not a Seq Scan:

```bash
$YSQLSH -d geospatial_test -c "
EXPLAIN (COSTS OFF)
SELECT md_pk, md_name, md_address, md_city, geom
FROM my_mapdata
WHERE LEFT(geo_hash10, 5) = ANY(
   ARRAY(SELECT geohash_cells_for_bbox(-105.09, 40.57, -105.06, 40.60, 5))
);"
```

Expected output:

```
                    QUERY PLAN
--------------------------------------------------
 Index Scan using ix_mapdata3 on my_mapdata
   Index Cond: ("left"(geo_hash10, 5) = ANY ($0))
   InitPlan 1 (returns $0)
     ->  ProjectSet
           ->  Result *RESULT*
```

Count matching rows:

```bash
$YSQLSH -d geospatial_test -c "
SELECT count(*) FROM my_mapdata
WHERE LEFT(geo_hash10, 5) = ANY(
   ARRAY(SELECT geohash_cells_for_bbox(-105.09, 40.57, -105.06, 40.60, 5))
);"
# Expected: 3140
```

---

## Part 6: Install GeoServer

GeoServer is the OGC-compliant map server that sits between the browser and
YugabyteDB. It requires Java 17+.

### 6a. Verify Java 17

```bash
/usr/lib/jvm/zulu-17.jdk/bin/java -version
# Expected: openjdk version "17.x.x"
```

If Java 17 is not at that path, find it:

```bash
find /usr/lib/jvm -name "java" -type f 2>/dev/null
```

### 6b. Download and extract

```bash
cd ~
curl -L -o geoserver-2.28.3-bin.zip \
  "https://sourceforge.net/projects/geoserver/files/GeoServer/2.28.3/geoserver-2.28.3-bin.zip/download"

rm -rf geoserver
mkdir geoserver
unzip -q -o geoserver-2.28.3-bin.zip -d geoserver
rm geoserver-2.28.3-bin.zip
```

Verify:

```bash
ls ~/geoserver/start.jar
```

### 6c. Start GeoServer

```bash
export JAVA_HOME=/usr/lib/jvm/zulu-17.jdk
export GEOSERVER_HOME=$HOME/geoserver

cd $GEOSERVER_HOME
$JAVA_HOME/bin/java -DENABLE_JSONP=true -jar start.jar &
```

Wait ~20 seconds for startup, then verify:

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/geoserver/web/
# Expected: 302 (redirect to login page)
```

GeoServer admin UI: http://localhost:8080/geoserver/web/?0
Login: `admin` / `geoserver`

---

## Part 7: Configure GeoServer (via REST API)

These commands configure GeoServer to connect to YugabyteDB and serve the
geohash-optimized SQL View.

### 7a. Create workspace

```bash
curl -u admin:geoserver -X POST http://localhost:8080/geoserver/rest/workspaces \
  -H "Content-Type: application/json" \
  -d '{"workspace":{"name":"yugabyte"}}'
```

### 7b. Create PostGIS data store

```bash
curl -u admin:geoserver -X POST \
  http://localhost:8080/geoserver/rest/workspaces/yugabyte/datastores \
  -H "Content-Type: application/json" \
  -d '{
  "dataStore": {
    "name": "geospatial_test",
    "type": "PostGIS",
    "connectionParameters": {
      "entry": [
        {"@key": "host", "$": "127.0.0.1"},
        {"@key": "port", "$": "5433"},
        {"@key": "database", "$": "geospatial_test"},
        {"@key": "schema", "$": "public"},
        {"@key": "user", "$": "yugabyte"},
        {"@key": "passwd", "$": ""},
        {"@key": "dbtype", "$": "postgis"},
        {"@key": "Expose primary keys", "$": "true"},
        {"@key": "Estimated extends", "$": "true"},
        {"@key": "Encode functions", "$": "true"},
        {"@key": "Loose bbox", "$": "true"},
        {"@key": "preparedStatements", "$": "false"}
      ]
    }
  }
}'
```

### 7c. Create the SQL View layer

This is the geohash-optimized query that GeoServer will execute:

```bash
curl -u admin:geoserver -X POST \
  "http://localhost:8080/geoserver/rest/workspaces/yugabyte/datastores/geospatial_test/featuretypes" \
  -H "Content-Type: application/json" \
  -d '{
  "featureType": {
    "name": "my_mapdata_fast",
    "nativeName": "my_mapdata_fast",
    "title": "my_mapdata_fast",
    "srs": "EPSG:4326",
    "metadata": {
      "entry": [
        {
          "@key": "JDBC_VIRTUAL_TABLE",
          "virtualTable": {
            "name": "my_mapdata_fast",
            "sql": "SELECT md_pk, md_name, md_address, md_city, md_province, md_postcode, md_category, md_subcategory, geom FROM my_mapdata WHERE LEFT(geo_hash10, 5) = ANY(ARRAY(SELECT geohash_cells_for_bbox(cast(%LON_MIN% as numeric), cast(%LAT_MIN% as numeric), cast(%LON_MAX% as numeric), cast(%LAT_MAX% as numeric), 5)))",
            "escapeSql": false,
            "keyColumn": "md_pk",
            "geometry": {
              "name": "geom",
              "type": "Point",
              "srid": 4326
            },
            "parameter": [
              {"name": "LON_MIN", "defaultValue": "-105.09", "regexpValidator": "^-?[\\d.]+$"},
              {"name": "LAT_MIN", "defaultValue": "40.57", "regexpValidator": "^-?[\\d.]+$"},
              {"name": "LON_MAX", "defaultValue": "-105.06", "regexpValidator": "^-?[\\d.]+$"},
              {"name": "LAT_MAX", "defaultValue": "40.60", "regexpValidator": "^-?[\\d.]+$"}
            ]
          }
        }
      ]
    }
  }
}'
```

### 7d. Verify GeoServer → YugabyteDB

```bash
curl -s "http://localhost:8080/geoserver/yugabyte/wfs?service=WFS&version=1.0.0&request=GetFeature&typeName=yugabyte:my_mapdata_fast&outputFormat=application/json&maxFeatures=3&viewparams=LON_MIN:-105.09;LAT_MIN:40.57;LON_MAX:-105.06;LAT_MAX:40.60" | python3 -m json.tool | head -20
```

Expected: GeoJSON with Fort Collins POIs.

---

## Part 8: Start the Demo Web App

### 8a. Install Python dependencies

```bash
pip3 install flask psycopg2-binary
```

### 8b. Update properties.ini

Edit `geospatial_demo/demo/properties.ini`:

```ini
[database]
DATABASE_HOST=127.0.0.1
DATABASE_PORT=5433
DATABASE_NAME=geospatial_test
DATABASE_USER=yugabyte
DATABASE_PASSWORD=
```

### 8c. Start the Flask app

```bash
cd geospatial_demo/demo
python3 60_index.py &
```

The app starts on port 5011.

### 8d. Verify

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:5011/
# Expected: 200
```

Open in browser: http://localhost:5011

If using SSH/Cursor Remote, forward ports 5011 and 8080.

---

## Part 9: Using the Demo

The web app has 3 tabs:

1. **Overview** — Presentation slides explaining the architecture
2. **Map View** — Interactive Leaflet map with 3 query modes:
   - **Circle** — Click to search 1-mile radius
   - **Box** — Click to search 1-square-mile area
   - **Polygon** — Click 6 points to define a polygon search
3. **RPC Calls** — Shows the WFS URL and SQL query being executed

The data flow is:
```
Browser → Flask (port 5011) → GeoServer (port 8080) → YugabyteDB (port 5433)
```

Every map request uses the two-phase geohash pattern:
`LEFT(geo_hash10, 5) = ANY(ARRAY(SELECT geohash_cells_for_bbox(...)))` which
produces an Index Scan on `ix_mapdata3`.

---

## Cleanup

To stop everything:

```bash
# Stop Flask
kill %2    # or: pkill -f "python3 60_index.py"

# Stop GeoServer
kill %1    # or: pkill -f "start.jar"

# Stop YugabyteDB
cd yugabyte-db && bin/yb-ctl stop
```

To remove GeoServer:

```bash
rm -rf ~/geoserver
```

To remove the extracted data file (keep the .gz):

```bash
rm geospatial_demo/data/19_mapData.pipe
```
