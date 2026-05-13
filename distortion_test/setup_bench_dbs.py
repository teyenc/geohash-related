#!/usr/bin/env python3
"""
Set up two clean benchmark DBs from the existing lat_bench data, with NO
cross-extension dependencies:

  gh_bench  : c_geohash (standalone) + Dan's pure-SQL geohash helpers.
              schema: latitude_test(id, band_lat, lat, lon, geohash10).
              no geom column, no S2, no PostGIS planner hook.

  s2_bench  : yb_geospatial_s2 only.
              schema: latitude_test(id, band_lat, lat, lon, geom).
              no gh-side surface; planner hook fires correctly here because
              this IS the system being measured.

Both DBs share the same synthetic point data (band_lat, lat, lon) -- we
COPY it out of lat_bench once, then COPY it into each new DB and let the
appropriate trigger fill the system-specific column / mapping table.
"""
import os
import subprocess
import sys
import time

YSQL = "/net/dev-server-te-yenchou/share/code/yugabyte-db/build/latest/postgres/bin/ysqlsh"
HOST = "127.0.0.1"
PORT = "5433"
USER = "yugabyte"

DUMP_CSV = "/tmp/latitude_test_dump.csv"
DANS_HELPERS = (
    "/net/dev-server-te-yenchou/share/code/geohash-related/distortion_test/"
    "dans_pure_sql_geohash.sql"
)


def psql(db, sql, capture=True):
    args = [YSQL, "-h", HOST, "-p", PORT, "-U", USER,
            "-X", "-v", "ON_ERROR_STOP=1", "-d", db]
    p = subprocess.run(args, input=sql, capture_output=capture, text=True)
    return p.returncode, p.stdout, p.stderr


def psql_file(db, path, capture=True):
    args = [YSQL, "-h", HOST, "-p", PORT, "-U", USER,
            "-X", "-v", "ON_ERROR_STOP=1", "-d", db, "-f", path]
    p = subprocess.run(args, capture_output=capture, text=True)
    return p.returncode, p.stdout, p.stderr


def dump_data():
    """COPY (band_lat, lat, lon) out of lat_bench.latitude_test to a CSV."""
    print(f"[dump] {DUMP_CSV}")
    rc, _, err = psql("lat_bench",
        f"\\copy (SELECT band_lat, lat, lon FROM latitude_test) "
        f"TO '{DUMP_CSV}' WITH (FORMAT csv, DELIMITER '|')")
    if rc != 0:
        print(f"  dump failed: {err}", file=sys.stderr); sys.exit(1)
    n = int(subprocess.run(["wc", "-l", DUMP_CSV],
                           capture_output=True, text=True).stdout.split()[0])
    print(f"  {n} rows dumped.")


def setup_gh_bench():
    print("\n=== gh_bench ===")
    psql("yugabyte", "DROP DATABASE IF EXISTS gh_bench;", capture=False)
    psql("yugabyte", "CREATE DATABASE gh_bench;", capture=False)

    print("[gh] CREATE EXTENSION c_geohash; install Dan's helpers")
    psql("gh_bench", "CREATE EXTENSION c_geohash;")
    rc, _, err = psql_file("gh_bench", DANS_HELPERS)
    if rc != 0:
        print(f"  Dan's helpers install failed: {err}", file=sys.stderr); sys.exit(1)

    # Bare table -- NO indexes, NO trigger yet. Indexes get built once at
    # the end after geohash10 is populated; that's much faster than
    # incremental updates per row. The trigger is hooked up afterwards so
    # future live INSERTs get the PostGIS-style auto-fill behavior.
    print("[gh] CREATE TABLE latitude_test (no indexes/trigger yet)")
    psql("gh_bench", """
        CREATE TABLE latitude_test (
            id        bigserial PRIMARY KEY,
            band_lat  double precision NOT NULL,
            lat       double precision NOT NULL,
            lon       double precision NOT NULL,
            geohash10 text
        );
    """)

    print(f"[gh] COPY raw (band_lat, lat, lon) into latitude_test...")
    t0 = time.time()
    rc, _, err = psql("gh_bench",
        f"\\copy latitude_test(band_lat, lat, lon) FROM '{DUMP_CSV}' "
        f"WITH (FORMAT csv, DELIMITER '|')",
        capture=True)
    if rc != 0:
        print(f"  COPY failed: {err}", file=sys.stderr); sys.exit(1)
    print(f"  loaded in {time.time() - t0:.1f}s")

    print(f"[gh] bulk UPDATE: geohash10 = c_geohash_encode(lat, lon, 10)")
    t0 = time.time()
    psql("gh_bench", """
        UPDATE latitude_test
           SET geohash10 = c_geohash_encode(lat, lon, 10);
    """)
    print(f"  filled in {time.time() - t0:.1f}s")

    print(f"[gh] build indexes (B-tree on geohash10 + LEFT(geohash10, 6)) "
          f"+ install trigger for future inserts")
    t0 = time.time()
    psql("gh_bench", """
        CREATE INDEX latitude_test_geohash10_idx
            ON latitude_test (geohash10 ASC);
        CREATE INDEX latitude_test_left_gh6_idx
            ON latitude_test (LEFT(geohash10, 6) ASC);
    """)
    # Now install the trigger -- no DISABLE/ENABLE dance needed because
    # bulk load is already done.
    psql("gh_bench", """
        CREATE OR REPLACE FUNCTION trg_geohash_install() RETURNS void
        LANGUAGE plpgsql AS $$
        BEGIN
            DROP TRIGGER IF EXISTS trg_geohash_latitude_test ON latitude_test;
            CREATE TRIGGER trg_geohash_latitude_test
              BEFORE INSERT OR UPDATE ON latitude_test
              FOR EACH ROW EXECUTE FUNCTION geohash_auto_encode('lat', 'lon', '10');
        END;
        $$;
        SELECT trg_geohash_install();
        DROP FUNCTION trg_geohash_install();
    """)
    print(f"  done in {time.time() - t0:.1f}s")

    rc, out, _ = psql("gh_bench", """
        SELECT count(*) AS rows,
               count(*) FILTER (WHERE geohash10 IS NOT NULL) AS gh_filled
          FROM latitude_test;
    """)
    print(f"  sanity: {out.strip()}")


def setup_s2_bench():
    print("\n=== s2_bench ===")
    psql("yugabyte", "DROP DATABASE IF EXISTS s2_bench;", capture=False)
    psql("yugabyte", "CREATE DATABASE s2_bench;", capture=False)

    print("[s2] CREATE EXTENSION yb_geospatial_s2 CASCADE")
    psql("s2_bench", "CREATE EXTENSION yb_geospatial_s2 CASCADE;")

    print("[s2] CREATE TABLE latitude_test + s2_index mapping (no trigger; "
          "we never need the geom column populated — recheck uses lat/lon "
          "bbox compare just like gh_bench, so both sides have the same "
          "predicate cost)")
    psql("s2_bench", """
        CREATE TABLE latitude_test (
            id        bigserial PRIMARY KEY,
            band_lat  double precision NOT NULL,
            lat       double precision NOT NULL,
            lon       double precision NOT NULL
        );
        -- s2 mapping table: (id, s2_cell) range-sharded on s2_cell ASC.
        CREATE TABLE latitude_test_s2_index (
            id      int8 NOT NULL,
            s2_cell int8 NOT NULL,
            PRIMARY KEY (s2_cell ASC, id)
        );
        CREATE INDEX latitude_test_s2_index_by_id
            ON latitude_test_s2_index (id);
    """)

    print(f"[s2] COPY raw (band_lat, lat, lon)...")
    t0 = time.time()
    rc, _, err = psql("s2_bench",
        f"\\copy latitude_test(band_lat, lat, lon) FROM '{DUMP_CSV}' "
        f"WITH (FORMAT csv, DELIMITER '|')",
        capture=True)
    if rc != 0:
        print(f"  COPY failed: {err}", file=sys.stderr); sys.exit(1)
    print(f"  loaded in {time.time() - t0:.1f}s")

    print(f"[s2] bulk-fill latitude_test_s2_index via inline ST_MakePoint "
          f"(one ST_S2Covering call per row, no geom column UPDATE step)...")
    t0 = time.time()
    psql("s2_bench", """
        INSERT INTO latitude_test_s2_index (id, s2_cell)
        SELECT id,
               unnest(ST_S2Covering(
                        ST_SetSRID(ST_MakePoint(lon, lat), 4326),
                        4, 18, 1000000))
          FROM latitude_test
        ON CONFLICT DO NOTHING;
    """)
    print(f"  s2_index filled in {time.time() - t0:.1f}s")

    # Install spatial_candidates_v2 (descendants + ancestors), parallel to
    # the gh side's geohash_candidates(...).
    print("[s2] install spatial_candidates_v2 helper")
    psql("s2_bench", """
        CREATE OR REPLACE FUNCTION spatial_candidates_v2(
            p_table_name text,
            p_query_geom geometry,
            p_min_level  int,
            p_max_level  int,
            p_max_cells  int
        ) RETURNS SETOF int8
        LANGUAGE plpgsql AS $fn$
        DECLARE
            idx_table   text := p_table_name || '_s2_index';
            query_cells int8[];
            cell        int8;
            range_min   int8;
            range_max   int8;
            ancestors   int8[];
            cur         int8;
            lsb         int8;
            new_lsb     int8;
            -- stop walking ancestors at level 4 (matches the s2_auto_index
            -- min_level used at insert time -- coarser than that, no row
            -- could be stored).
            stop_lsb    int8 := 1::int8 << (2 * (30 - 4));
        BEGIN
            query_cells := ST_S2Covering(
                p_query_geom, p_min_level, p_max_level, p_max_cells);
            FOR i IN 1..coalesce(array_length(query_cells, 1), 0) LOOP
                cell      := query_cells[i];
                range_min := cell - ((cell & (-cell)) - 1);
                range_max := cell + ((cell & (-cell)) - 1);
                ancestors := ARRAY[]::int8[];
                cur := cell;
                LOOP
                    lsb := cur & (-cur);
                    EXIT WHEN lsb >= stop_lsb;
                    new_lsb := lsb << 2;
                    cur := (cur & (-new_lsb)) | new_lsb;
                    ancestors := ancestors || cur;
                END LOOP;
                RETURN QUERY EXECUTE format(
                    'SELECT id FROM %I WHERE s2_cell BETWEEN $1 AND $2 '
                    'UNION ALL '
                    'SELECT id FROM %I WHERE s2_cell = ANY($3)',
                    idx_table, idx_table)
                USING range_min, range_max, ancestors;
            END LOOP;
        END;
        $fn$;
    """)

    rc, out, _ = psql("s2_bench", """
        SELECT
          (SELECT count(*) FROM latitude_test) AS rows,
          (SELECT count(*) FROM latitude_test_s2_index) AS s2_idx_rows;
    """)
    print(f"  sanity: {out.strip()}")


def main():
    if not os.path.exists(DANS_HELPERS):
        print(f"ERROR: missing {DANS_HELPERS}", file=sys.stderr); sys.exit(1)
    dump_data()
    setup_gh_bench()
    setup_s2_bench()
    print("\nDone. gh_bench and s2_bench are ready.")


if __name__ == "__main__":
    main()
