#!/usr/bin/env bash
# ============================================================================
# 06_setup_geocities.sh
#
# Downloads cities500 from GeoNames (~185K globally-distributed cities,
# 13 MB compressed) and loads it into bench_cgeo / bench_qz / bench_s2 as
# a new table `geo_cities`, parallel to my_mapdata.
#
# Why we need this:
#   my_mapdata's 344K POIs are 99% clustered in lat 38-42 / lon -112..-105
#   (Denver / Salt Lake City corridor — Dan's demo area). Latency-sweep
#   envelopes at our test (lat, lon) anchors all hit zero rows there, so
#   only the cell-cover side of the query is exercised; the inner Index
#   Scan + recheck never fires. cities500 has global coverage so most
#   test envelopes catch enough rows for the recheck path to be meaningful.
#
# What this script does NOT do:
#   * Load into bench_dans (pure_sql). Pure_sql needs a precomputed
#     geo_hash10 column on every row; cities500 doesn't have one and
#     computing it in plpgsql across 185K rows is slow. Pure_sql remains
#     usable against my_mapdata via `latency_sweep.py --with-pure-sql`.
#   * Load into bench_postgis. That DB belongs to the Set 1 perf bench
#     (s2_vs_geohash_benchmark/run_benchmark*.sh), not the distortion
#     experiment.
#
# License: GeoNames data is Creative Commons Attribution 4.0
#   https://www.geonames.org/export/
# ============================================================================
set -euo pipefail

YB_BIN=/net/dev-server-te-yenchou/share/code/yugabyte-db/build/latest/postgres/bin
ROOT=$(cd "$(dirname "$0")"/..; pwd)
DATA_DIR=$ROOT/data
mkdir -p "$DATA_DIR"

# cities500: every populated place with > 500 inhabitants. ~185K rows, 13 MB
# compressed. Picked over cities5000/cities1000 because at our chosen
# longitude (lon=15, European corridor) the lower-density datasets left
# many test envelopes with zero hits. cities500 catches every town and
# yields ~10-50 hits per non-arctic envelope at lon=15.
CITIES_URL="https://download.geonames.org/export/dump/cities500.zip"
CITIES_ZIP=$DATA_DIR/cities500.zip
CITIES_TSV=$DATA_DIR/cities500.txt
CITIES_PIPE=$DATA_DIR/geo_cities.pipe

PSQL=( "$YB_BIN/ysqlsh" -h 127.0.0.1 -p 5433 -U yugabyte -v ON_ERROR_STOP=1 -X )

# ---- skip-check helper: does <db> already have geo_cities populated? -------
already_loaded() {
    local db="$1" idx_check="$2"
    local out
    out=$("$YB_BIN/ysqlsh" -h 127.0.0.1 -p 5433 -U yugabyte -d "$db" -tA \
            -c "SELECT (SELECT count(*) FROM geo_cities) || '|' || ($idx_check)" \
            2>/dev/null) || return 1
    # cities500 has ~185K rows; accept anything > 100K as "loaded".
    local rows="${out%%|*}"
    local mapping_ok="${out##*|}"
    [ "$rows" -ge 100000 ] && [ "$mapping_ok" = "1" ]
}

# ============================================================================
# Step 1: download + unzip + transform to pipe format (idempotent)
# ============================================================================
if [ ! -s "$CITIES_TSV" ]; then
    if [ ! -s "$CITIES_ZIP" ]; then
        echo "[geocities] downloading $CITIES_URL"
        curl -L -o "$CITIES_ZIP" "$CITIES_URL"
    fi
    echo "[geocities] unzipping"
    unzip -o "$CITIES_ZIP" -d "$DATA_DIR" >/dev/null
fi
echo "[geocities] TSV: $(wc -l < "$CITIES_TSV") rows at $CITIES_TSV"

if [ ! -s "$CITIES_PIPE" ] || [ "$CITIES_TSV" -nt "$CITIES_PIPE" ]; then
    echo "[geocities] transforming TSV -> $CITIES_PIPE"
    # GeoNames TSV columns:
    #   $1=geonameid   $2=name   $3=asciiname   $4=alternatenames
    #   $5=latitude    $6=longitude   $7=feature_class   $8=feature_code
    #   $9=country_code   ...
    # Output pipe columns: md_pk | md_lat | md_lng | md_name | md_country
    # (md_name uses asciiname so we never have non-ASCII characters that
    # might trip parsers; pipe chars are scrubbed defensively.)
    awk -F'\t' '
        BEGIN { OFS="|" }
        {
            gsub(/\|/, "", $3)
            print $1, $5, $6, $3, $9
        }
    ' "$CITIES_TSV" > "$CITIES_PIPE"
fi
echo "[geocities] pipe: $(wc -l < "$CITIES_PIPE") rows at $CITIES_PIPE"

# ============================================================================
# Step 2: per-engine DB blocks
# ============================================================================
# Shared schema. Column names match the my_mapdata convention (md_pk,
# md_lat, md_lng, geom) so the sweep's query templates work unchanged
# once --table=geo_cities is selected — only the FROM table name changes.

SCHEMA_SQL="
DROP TABLE IF EXISTS geo_cities CASCADE;
CREATE TABLE geo_cities (
    md_pk      BIGINT PRIMARY KEY,
    md_lat     TEXT,
    md_lng     TEXT,
    md_name    TEXT,
    md_country TEXT,
    geom       geometry
);
"

# ---- bench_cgeo --------------------------------------------------------------
echo ""
echo "=== bench_cgeo ==="
if already_loaded bench_cgeo \
       "SELECT (count(*) > 0)::int FROM geo_cities_cgeo_index"; then
    echo "[geocities/cgeo] already loaded — skipping rebuild."
else
    "${PSQL[@]}" -d bench_cgeo <<SQL
$SCHEMA_SQL
SELECT create_cgeo_text_spatial_index('geo_cities', 'geom', 'md_pk', 10);
ALTER TABLE geo_cities DISABLE TRIGGER trg_cgeo_geo_cities;
\\copy geo_cities(md_pk, md_lat, md_lng, md_name, md_country) FROM '$CITIES_PIPE' WITH (FORMAT csv, DELIMITER '|', ROWS_PER_TRANSACTION 5000)
UPDATE geo_cities
   SET geom = ST_GeomFromText('POINT(' || md_lng || ' ' || md_lat || ')', 4326)
 WHERE md_lat IS NOT NULL AND md_lng IS NOT NULL;
ALTER TABLE geo_cities ENABLE TRIGGER trg_cgeo_geo_cities;
INSERT INTO geo_cities_cgeo_index (entry_id, geohash)
SELECT md_pk, c_geohash_encode(ST_Y(geom), ST_X(geom), 10)
  FROM geo_cities WHERE geom IS NOT NULL
ON CONFLICT DO NOTHING;
SELECT 'geo_cities' AS tbl, count(*) FROM geo_cities
UNION ALL
SELECT 'geo_cities_cgeo_index', count(*) FROM geo_cities_cgeo_index;
SQL
fi

# ---- bench_qz ----------------------------------------------------------------
echo ""
echo "=== bench_qz ==="
if already_loaded bench_qz \
       "SELECT (count(*) > 0)::int FROM geo_cities_qz_index"; then
    echo "[geocities/qz] already loaded — skipping rebuild."
else
    "${PSQL[@]}" -d bench_qz <<SQL
$SCHEMA_SQL
-- qz mapping is a hand-built table, not auto-created by an extension, so
-- the geo_cities CASCADE above doesn't drop it. Drop explicitly.
DROP TABLE IF EXISTS geo_cities_qz_index CASCADE;
CREATE TABLE geo_cities_qz_index (
    entry_id int8 NOT NULL,
    qz_path  text NOT NULL,
    PRIMARY KEY (qz_path ASC, entry_id)
);
CREATE INDEX geo_cities_qz_index_by_entry_id ON geo_cities_qz_index (entry_id);
\\copy geo_cities(md_pk, md_lat, md_lng, md_name, md_country) FROM '$CITIES_PIPE' WITH (FORMAT csv, DELIMITER '|', ROWS_PER_TRANSACTION 5000)
UPDATE geo_cities
   SET geom = ST_GeomFromText('POINT(' || md_lng || ' ' || md_lat || ')', 4326)
 WHERE md_lat IS NOT NULL AND md_lng IS NOT NULL;
INSERT INTO geo_cities_qz_index (entry_id, qz_path)
SELECT md_pk, c_qz_encode_str(ST_X(geom), ST_Y(geom), 18)
  FROM geo_cities WHERE geom IS NOT NULL
ON CONFLICT DO NOTHING;
SELECT 'geo_cities' AS tbl, count(*) FROM geo_cities
UNION ALL
SELECT 'geo_cities_qz_index', count(*) FROM geo_cities_qz_index;
SQL
fi

# ---- bench_s2 ----------------------------------------------------------------
echo ""
echo "=== bench_s2 ==="
if already_loaded bench_s2 \
       "SELECT (count(*) > 0)::int FROM geo_cities_s2_index"; then
    echo "[geocities/s2] already loaded — skipping rebuild."
else
    "${PSQL[@]}" -d bench_s2 <<SQL
$SCHEMA_SQL
SELECT create_spatial_index('geo_cities', 'geom', 'md_pk');
ALTER TABLE geo_cities DISABLE TRIGGER trg_s2_geo_cities;
\\copy geo_cities(md_pk, md_lat, md_lng, md_name, md_country) FROM '$CITIES_PIPE' WITH (FORMAT csv, DELIMITER '|', ROWS_PER_TRANSACTION 5000)
UPDATE geo_cities
   SET geom = ST_GeomFromText('POINT(' || md_lng || ' ' || md_lat || ')', 4326)
 WHERE md_lat IS NOT NULL AND md_lng IS NOT NULL;
ALTER TABLE geo_cities ENABLE TRIGGER trg_s2_geo_cities;
INSERT INTO geo_cities_s2_index (entry_id, s2_cell)
SELECT md_pk, unnest(ST_S2Covering(geom, 10, 20))
  FROM geo_cities WHERE geom IS NOT NULL
ON CONFLICT DO NOTHING;
SELECT 'geo_cities' AS tbl, count(*) FROM geo_cities
UNION ALL
SELECT 'geo_cities_s2_index', count(*) FROM geo_cities_s2_index;
SQL
fi

echo ""
echo "[geocities] done."
