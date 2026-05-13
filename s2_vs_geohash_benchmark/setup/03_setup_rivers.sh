#!/usr/bin/env bash
# ==============================================================================
# 03_setup_rivers.sh
#
# Loads 100,000 synthetic rivers (LineStrings) into all four benchmark DBs:
#   - bench_postgis : rivers(id, name, geom geometry(LineString, 4326)) + GiST
#   - bench_dans    : rivers(id, name, geom geometry)           -- Dan's (lon[],lat[])
#                                                               -- NO INDEX (by design;
#                                                               -- geohash-per-row can't
#                                                               -- cover a line)
#   - bench_s2      : rivers(id, name, geom geometry) + S2 auto-index trigger
#   - bench_cgeo    : rivers(id, name, geom geometry) + c_geohash mapping
#                     (index_prec=5, ~5 km cells)
#
# Resilience: each engine's block is guarded by an existence check on its
# DB and the corresponding cluster. Missing DBs (or unreachable clusters)
# are skipped with a warning rather than aborting the whole script — so you
# can run this even if you only set up a subset of the four engines.
#
# Recommended order: 00 → 01 → 02 → 04 → 03 (bootstrap.sh does this).
# ==============================================================================
set -euo pipefail

ROOT=$(cd "$(dirname "$0")"/..; pwd)
DATA="$ROOT/data/rivers.csv"
YB_BIN=/net/dev-server-te-yenchou/share/code/yugabyte-db/build/latest/postgres/bin
PG_BIN=/usr/pgsql-15/bin

# Track outcomes for the final summary.
LOADED=()
SKIPPED=()

# Returns 0 if the named DB exists on the PG15 cluster (and the cluster is
# reachable), 1 otherwise. Connects to the always-present `postgres` DB so
# the probe works even if the target DB doesn't exist.
pg15_db_exists() {
    $PG_BIN/psql -h 127.0.0.1 -p 54321 -d postgres -tA \
        -c "SELECT 1 FROM pg_database WHERE datname='$1'" 2>/dev/null \
      | grep -q 1
}

# Same for the YB cluster on :5433 (probes via the `yugabyte` admin DB).
yb_db_exists() {
    $YB_BIN/ysqlsh -h 127.0.0.1 -p 5433 -U yugabyte -d yugabyte -tA \
        -c "SELECT 1 FROM pg_database WHERE datname='$1'" 2>/dev/null \
      | grep -q 1
}

skip() {
    echo "[rivers] SKIP $1 -- $2"
    SKIPPED+=("$1")
}

# Returns 0 if `rivers` in <db> has exactly 100000 rows AND the supplied
# mapping table (or pg_class entry for a non-mapping engine) is present.
# Args: <psql-cmd> <db> <mapping-check-sql>
# The mapping-check-sql must return '1' on success, anything else on failure
# (e.g. empty, '0').  This is what lets each engine's pre-check vary.
rivers_already_loaded() {
    local cmd="$1" db="$2" mapping_sql="$3" out
    out=$($cmd -d "$db" -tA \
            -c "SELECT (SELECT count(*) FROM rivers) || '|' || ($mapping_sql)" \
            2>/dev/null) || return 1
    [ "$out" = "100000|1" ]
}
ALREADY=()  # engines whose rivers were already loaded

if [ ! -s "$DATA" ]; then
  echo "[rivers] generating $DATA"
  mkdir -p "$(dirname "$DATA")"
  python3 "$ROOT/setup/gen_rivers.py" > "$DATA"
fi
echo "[rivers] dataset: $(wc -l < "$DATA") lines"

# ---------- PostGIS ----------
echo ""
if pg15_db_exists bench_postgis; then
if rivers_already_loaded "$PG_BIN/psql -h 127.0.0.1 -p 54321" bench_postgis \
       "SELECT count(*) FROM pg_class WHERE relname='ix_rivers_geom_gist'"; then
echo "[rivers] bench_postgis already loaded (rivers=100000, GiST index present) -- skipping."
ALREADY+=("bench_postgis")
else
echo "[rivers] loading into bench_postgis ..."
$PG_BIN/psql -h 127.0.0.1 -p 54321 -d bench_postgis -v ON_ERROR_STOP=1 -qX <<SQL
DROP TABLE IF EXISTS rivers CASCADE;
CREATE TABLE rivers (
  id        BIGINT PRIMARY KEY,
  name      TEXT,
  wkt       TEXT,
  lon_array TEXT,
  lat_array TEXT,
  geom      geometry(LineString, 4326)
);
\copy rivers(id, name, wkt, lon_array, lat_array) FROM '$DATA' WITH (FORMAT csv, DELIMITER '|', HEADER true)
UPDATE rivers SET geom = ST_GeomFromText(wkt, 4326);
CREATE INDEX ix_rivers_geom_gist ON rivers USING GIST (geom);
ANALYZE rivers;
SELECT 'rivers' AS tbl, count(*) AS n, pg_size_pretty(pg_relation_size('ix_rivers_geom_gist')) AS gist FROM rivers;
SQL
LOADED+=("bench_postgis")
fi  # end rivers_already_loaded
else
skip bench_postgis "PG15 unreachable on :54321 or DB missing (run 00_setup_postgis.sh)"
fi

# ---------- Dan's ----------
echo ""
if yb_db_exists bench_dans; then
# Dan's has no separate mapping for rivers (by design — geohash-per-row can't
# cover a line), so we only check that the rivers table itself is at 100000.
if rivers_already_loaded "$YB_BIN/ysqlsh -h 127.0.0.1 -p 5433 -U yugabyte" bench_dans \
       "SELECT 1"; then
echo "[rivers] bench_dans already loaded (rivers=100000, no index by design) -- skipping."
ALREADY+=("bench_dans")
else
echo "[rivers] loading into bench_dans ..."
$YB_BIN/ysqlsh -h 127.0.0.1 -p 5433 -U yugabyte -d bench_dans -v ON_ERROR_STOP=1 -qX <<SQL
DROP TABLE IF EXISTS rivers CASCADE;
CREATE TABLE rivers (
  id        BIGINT PRIMARY KEY,
  name      TEXT,
  wkt       TEXT,
  lon_array TEXT,
  lat_array TEXT,
  geom      geometry    -- Dan's custom composite type: (lon double[], lat double[])
);
\copy rivers(id, name, wkt, lon_array, lat_array) FROM '$DATA' WITH (FORMAT csv, DELIMITER '|', HEADER true)
UPDATE rivers
   SET geom = (
     ROW(lon_array::double precision[], lat_array::double precision[])::geometry
   );
-- Deliberately NO index: Dan's schema only supports one geohash per row, which
-- cannot represent a multi-cell line.  Queries will seq-scan.
SELECT 'rivers' AS tbl, count(*) AS n FROM rivers;
SQL
LOADED+=("bench_dans")
fi  # end rivers_already_loaded
else
skip bench_dans "YB unreachable on :5433 or DB missing (run 01_setup_yb_dans.sh)"
fi

# ---------- S2 ----------
echo ""
if yb_db_exists bench_s2; then
if rivers_already_loaded "$YB_BIN/ysqlsh -h 127.0.0.1 -p 5433 -U yugabyte" bench_s2 \
       "SELECT LEAST(
            (SELECT (count(*) > 0)::int FROM rivers_s2_index),
            (SELECT count(*) FROM pg_class WHERE relname='rivers_s2_index_by_entry_id')
        )"; then
echo "[rivers] bench_s2 already loaded (rivers=100000, s2 mapping filled, secondary idx present) -- skipping."
ALREADY+=("bench_s2")
else
echo "[rivers] loading into bench_s2 ..."
$YB_BIN/ysqlsh -h 127.0.0.1 -p 5433 -U yugabyte -d bench_s2 -v ON_ERROR_STOP=1 -qX <<SQL
DROP TABLE IF EXISTS rivers CASCADE;
CREATE TABLE rivers (
  id   BIGINT PRIMARY KEY,
  name TEXT,
  wkt  TEXT,
  geom geometry
);

SELECT create_spatial_index('rivers', 'geom', 'id');
ALTER TABLE rivers DISABLE TRIGGER trg_s2_rivers;

\copy rivers(id, name, wkt) FROM PROGRAM 'awk -F"|" ''NR > 1 {print \$1 "|" \$2 "|" \$3}'' $DATA' WITH (FORMAT csv, DELIMITER '|')

UPDATE rivers SET geom = ST_GeomFromText(wkt, 4326);

-- Bulk-populate the S2 mapping table (same as POI setup).
INSERT INTO rivers_s2_index (entry_id, s2_cell)
SELECT id, unnest(ST_S2Covering(geom, 10, 20))
  FROM rivers
 WHERE geom IS NOT NULL
ON CONFLICT DO NOTHING;

ALTER TABLE rivers ENABLE TRIGGER trg_s2_rivers;

SELECT 'rivers'          AS tbl, count(*) AS n FROM rivers
UNION ALL
SELECT 'rivers_s2_index',         count(*)      FROM rivers_s2_index;
SQL
LOADED+=("bench_s2")
fi  # end rivers_already_loaded
else
skip bench_s2 "YB unreachable on :5433 or DB missing (run 02_setup_yb_s2.sh)"
fi

# ---------- c_geohash ----------
echo ""
if yb_db_exists bench_cgeo; then
if rivers_already_loaded "$YB_BIN/ysqlsh -h 127.0.0.1 -p 5433 -U yugabyte" bench_cgeo \
       "SELECT LEAST(
            (SELECT (count(*) > 0)::int FROM rivers_cgeo_index),
            (SELECT count(*) FROM pg_class WHERE relname='rivers_cgeo_index_by_entry_id')
        )"; then
echo "[rivers] bench_cgeo already loaded (rivers=100000, cgeo mapping filled, secondary idx present) -- skipping."
ALREADY+=("bench_cgeo")
else
echo "[rivers] loading into bench_cgeo ..."
$YB_BIN/ysqlsh -h 127.0.0.1 -p 5433 -U yugabyte -d bench_cgeo -v ON_ERROR_STOP=1 -qX <<SQL
DROP TABLE IF EXISTS rivers CASCADE;
CREATE TABLE rivers (
  id   BIGINT PRIMARY KEY,
  name TEXT,
  wkt  TEXT,
  geom geometry
);

-- Rivers: index at level 5 (~5 km cells). A 75 km river bbox fans out to
-- O((75/5)^2) ≈ 225 cells worst case; in practice rivers cluster near the
-- diagonal so it averages much less.
SELECT create_cgeo_text_spatial_index('rivers', 'geom', 'id', 5);
ALTER TABLE rivers DISABLE TRIGGER trg_cgeo_rivers;

\copy rivers(id, name, wkt) FROM PROGRAM 'awk -F"|" ''NR > 1 {print \$1 "|" \$2 "|" \$3}'' $DATA' WITH (FORMAT csv, DELIMITER '|')

UPDATE rivers SET geom = ST_GeomFromText(wkt, 4326);

-- Drive cells from the adaptive coverer with min_prec=max_prec=5 so every
-- emitted cell is at exactly the storage level. Each pair's min10 is the
-- cell already right-padded with '0' to 10 chars, ready to insert.
INSERT INTO rivers_cgeo_index (entry_id, geohash)
SELECT r.id, p.cell
  FROM rivers r,
       LATERAL (
         SELECT pairs[2 * i - 1] AS cell
           FROM (
             SELECT c_geohash_cover_geometry(r.geom, 5, 5, 1000000) AS pairs
           ) c,
           generate_series(1, coalesce(array_length(c.pairs, 1), 0) / 2) i
       ) p
 WHERE r.geom IS NOT NULL
ON CONFLICT DO NOTHING;

ALTER TABLE rivers ENABLE TRIGGER trg_cgeo_rivers;

SELECT 'rivers'            AS tbl, count(*) AS n FROM rivers
UNION ALL
SELECT 'rivers_cgeo_index',         count(*)      FROM rivers_cgeo_index;
SQL
LOADED+=("bench_cgeo")
fi  # end rivers_already_loaded
else
skip bench_cgeo "YB unreachable on :5433 or DB missing (run 04_setup_yb_cgeo.sh)"
fi

# ---------- final summary ----------
echo ""
echo "============================================================"
echo "[rivers] summary"
if [ ${#LOADED[@]}  -gt 0 ]; then echo "  loaded:    ${LOADED[*]}";    fi
if [ ${#ALREADY[@]} -gt 0 ]; then echo "  unchanged: ${ALREADY[*]}";   fi
if [ ${#SKIPPED[@]} -gt 0 ]; then echo "  skipped:   ${SKIPPED[*]}";   fi
echo "============================================================"
