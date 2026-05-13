#!/usr/bin/env bash
# ============================================================================
# 01_setup_yb_dans.sh
#
# Creates YB database `bench_dans`, applies Dan's geohash SQL functions and
# schema, and loads the 344K-row POI dataset with pre-computed geohashes.
# ============================================================================
set -euo pipefail

YB_BIN=/net/dev-server-te-yenchou/share/code/yugabyte-db/build/latest/postgres/bin
DANS_SQL="/net/dev-server-te-yenchou/share/code/geospatial_v05/20 - sql"
DATA_PIPE="$DANS_SQL/19_mapData.pipe"

PSQL=( "$YB_BIN/ysqlsh" -h 127.0.0.1 -p 5433 -U yugabyte -v ON_ERROR_STOP=1 -X )

# ---- early-out if bench_dans is already fully loaded ------------------------
# Skip the destructive DROP DATABASE + reload (~90s) when bench_dans exists,
# my_mapdata holds the full 344688 rows, AND the LEFT(geo_hash10,6) expr index
# is present. Any probe failure (cluster down, DB missing, count mismatch)
# falls through to the destructive path below.
already_loaded() {
    local out
    out=$("$YB_BIN/ysqlsh" -h 127.0.0.1 -p 5433 -U yugabyte -d bench_dans -tA \
            -c "SELECT (SELECT count(*) FROM my_mapdata) || '|' ||
                       (SELECT count(*) FROM pg_class
                         WHERE relname='my_mapdata_left_gh6_idx')" 2>/dev/null) || return 1
    [ "$out" = "344688|1" ]
}
if already_loaded; then
    echo "[yb-dans] bench_dans already loaded (my_mapdata=344688, LEFT(gh6) idx present) -- skipping rebuild."
    exit 0
fi

echo "[yb-dans] dropping + recreating bench_dans"
"${PSQL[@]}" -d yugabyte <<SQL
DROP DATABASE IF EXISTS bench_dans;
CREATE DATABASE bench_dans;
SQL

DANS_PSQL=( "$YB_BIN/ysqlsh" -h 127.0.0.1 -p 5433 -U yugabyte -v ON_ERROR_STOP=1 -X -d bench_dans )

echo "[yb-dans] applying Dan's SQL modules..."
for f in \
   "$DANS_SQL/10_CreateGeometryType.sql" \
   "$DANS_SQL/11_CreateSchema.sql" \
   "$DANS_SQL/12_CreateGeographyType.sql" \
   "$DANS_SQL/20_GeohashFunctions.sql" \
   "$DANS_SQL/25_GeometryFunctions.sql" \
   "$DANS_SQL/26_Tier1_GeometryFunctions.sql" \
   "$DANS_SQL/27_Tier2_GeometryFunctions.sql" \
   "$DANS_SQL/28_Tier3_GeometryFunctions.sql" \
   "$DANS_SQL/30_GeohashPolygonFunctions.sql" \
   "$DANS_SQL/31_GeohashBboxFunctions.sql"; do
  echo "    -- $(basename "$f")"
  "${DANS_PSQL[@]}" -f "$f" > /dev/null
done

echo "[yb-dans] loading 344K rows (this takes a minute in YB)..."
"${DANS_PSQL[@]}" <<SQL
\\copy my_mapdata(md_pk, md_lat, md_lng, geo_hash10, md_name, md_address, md_city, md_province, md_country, md_postcode, md_phone, md_category, md_subcategory, md_mysource, md_tags, md_type) FROM '$DATA_PIPE' WITH (FORMAT csv, DELIMITER '|', HEADER true, ROWS_PER_TRANSACTION 5000)

UPDATE my_mapdata
   SET geom = ST_MakePoint(md_lng::double precision, md_lat::double precision)
 WHERE md_lat IS NOT NULL AND md_lng IS NOT NULL;

UPDATE my_mapdata
   SET geo_hash8 = LEFT(geo_hash10, 8)
 WHERE geo_hash10 IS NOT NULL;

-- LEFT(geo_hash10, 6) expression index for the distortion-sweep pure-SQL
-- path (LEFT(geo_hash10, 6) = ANY(geohash_cells_for_bbox(...))). Without
-- this the candidate scan reduces to a 344K seq-scan; with it, the bucketed
-- prefix lookup costs only a handful of cells per envelope.
CREATE INDEX IF NOT EXISTS my_mapdata_left_gh6_idx
    ON my_mapdata (LEFT(geo_hash10, 6) ASC);
SQL

"${DANS_PSQL[@]}" -c "SELECT count(*) AS rows FROM my_mapdata;"
echo "[yb-dans] done."
