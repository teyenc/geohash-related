#!/usr/bin/env python3
"""
End-to-end Phase 2+3 setup for the latitude-distortion benchmark.

What this does, in order:
  1. Drop+recreate database `lat_bench` on the running YB cluster.
  2. Install c_geohash and yb_geospatial_s2 extensions.
  3. Create `latitude_test` table: (id, lat, lon, geom, geohash10).
     - gh side: create_geohash_index() (from c_geohash) installs the
       B-tree on geohash10 and a BEFORE INSERT/UPDATE trigger that auto-
       fills geohash10 from (lat, lon).
     - S2 side: create_spatial_index() (from yb_geospatial_s2) builds the
       S2 mapping table and the s2_auto_index trigger; we disable that
       trigger for bulk load.
  4. Generate ~50k uniform points within ±100 km of each test latitude
     (lat ∈ {0, 30, 45, 60, 70, 80, 85, 87, 89}). 9 × 50k = ~450k rows.
     "Uniform" means uniform on the surface within a geodesic neighborhood
     (azimuthal-equidistant projection trick).
  5. COPY into staging table → INSERT into final table. The gh trigger
     auto-fills geohash10 per row; geom is built inline via ST_MakePoint.
  6. Bulk-build the S2 mapping after disabling the trigger, then re-enable.

Configuration matches the agreed plan:
  - all 9 test latitudes
  - 50k points per latitude, ~100 km neighborhood radius
  - geohash precision 10 (matches the geohash10 column width)
  - S2 max_level 18 (matches our function-level proof's (p7, L16) pair —
    L18 is the deeper-by-one match for p10's storage granularity).

Run from a terminal where you can type `! ` to approve permission prompts.
"""

import csv
import math
import os
import random
import subprocess
import sys
import tempfile
import time

YB_BIN = "/net/dev-server-te-yenchou/share/code/yugabyte-db/build/latest/postgres/bin"
YSQL = os.path.join(YB_BIN, "ysqlsh")
HOST = "127.0.0.1"
PORT = "5433"
USER = "yugabyte"
DB = "lat_bench"

LATITUDES = [0, 30, 45, 60, 70, 80, 85, 87, 89]
# Center longitudes for each band — a list of "unlucky" positions that are
# not clean fractions of 90° (so they're outside the geohash lucky-alignment
# regime). The benchmark sweeps queries at the SAME longitudes against this
# data.
LONGITUDES = [7.0, 31.0, 55.0, 79.0]
# Spacing 24° — chosen to exceed the cluster-overlap threshold at the
# highest test latitude (lat=87°). At that lat, each 100 km cluster spans
# ~17° in lon and a 75 km query's bbox is ~26° wide; spacings of ~22° or
# more keep neighboring clusters from polluting each other's queries.
# Each lon is verified unlucky for both r=25 and r=75 at lat=0°
# (re-verify when changing this list).
POINTS_PER_LAT_PER_LON = 50000
NEIGHBORHOOD_KM = 100.0
GEOHASH_PRECISION = 10
S2_INDEX_MIN_LEVEL = 4
S2_INDEX_MAX_LEVEL = 18
EARTH_R_KM = 6371.0088


def run_sql(sql, db=DB, fetch=False):
    args = [YSQL, "-h", HOST, "-p", PORT, "-U", USER,
            "-v", "ON_ERROR_STOP=1", "-X", "-d", db]
    if fetch:
        args += ["-t", "-A"]
    args += ["-c", sql]
    return subprocess.run(args, check=True, capture_output=True, text=True)


def gen_uniform_points(center_lat, center_lon, radius_km, n, rng):
    """
    Sample n points uniformly within a geodesic disk of radius radius_km
    centered at (center_lat, center_lon). Uses the standard azimuthal-
    equidistant trick: pick (r, theta) in the projected plane such that
    points are uniform by area, then unproject.

    Cap latitudes to [-89.9, 89.9] just in case (the disk shouldn't reach
    the pole at our parameters, but be defensive).
    """
    lat_rad = math.radians(center_lat)
    lon_rad = math.radians(center_lon)
    out = []
    for _ in range(n):
        # Uniform-area sample: r = R * sqrt(u), theta = 2pi * v.
        r_km = radius_km * math.sqrt(rng.random())
        theta = 2.0 * math.pi * rng.random()
        # Convert to angular distance on the sphere.
        delta = r_km / EARTH_R_KM  # radians
        sin_d = math.sin(delta)
        cos_d = math.cos(delta)
        # Forward geodesic from (center_lat, center_lon) at bearing theta,
        # distance delta on a unit sphere.
        sin_lat0 = math.sin(lat_rad)
        cos_lat0 = math.cos(lat_rad)
        new_lat = math.asin(sin_lat0 * cos_d
                            + cos_lat0 * sin_d * math.cos(theta))
        new_lon = lon_rad + math.atan2(
            math.sin(theta) * sin_d * cos_lat0,
            cos_d - sin_lat0 * math.sin(new_lat))
        new_lat_deg = max(-89.9, min(89.9, math.degrees(new_lat)))
        new_lon_deg = math.degrees(new_lon)
        # Wrap longitude to [-180, 180).
        new_lon_deg = ((new_lon_deg + 180.0) % 360.0) - 180.0
        out.append((new_lat_deg, new_lon_deg))
    return out


def main():
    total_rows = len(LATITUDES) * len(LONGITUDES) * POINTS_PER_LAT_PER_LON
    print("Phase 2+3: end-to-end setup")
    print(f"  test latitudes      : {LATITUDES}")
    print(f"  center longitudes   : {LONGITUDES}")
    print(f"  points per (lat,lon): {POINTS_PER_LAT_PER_LON}")
    print(f"  neighborhood        : ±{NEIGHBORHOOD_KM} km")
    print(f"  total rows          : {total_rows}")
    print()

    # 1+2. Database and extensions
    print("[1/6] (re)creating database lat_bench + extensions...")
    run_sql(f"DROP DATABASE IF EXISTS {DB};", db="yugabyte")
    run_sql(f"CREATE DATABASE {DB};", db="yugabyte")
    run_sql("CREATE EXTENSION c_geohash;")
    run_sql("CREATE EXTENSION yb_geospatial_s2 CASCADE;")

    # 3. Table + index + S2 mapping
    print("[2/6] creating schema...")
    run_sql("""
        CREATE TABLE latitude_test (
            id        bigserial PRIMARY KEY,
            band_lat  double precision NOT NULL,
            lat       double precision NOT NULL,
            lon       double precision NOT NULL,
            geohash10 text,
            geom      geometry
        );
    """)
    # gh side: c_geohash's create_geohash_index() installs an ASC B-tree on
    # geohash10 and a BEFORE INSERT/UPDATE trigger that auto-fills geohash10
    # from (lat, lon). Parallel to the S2 setup below.
    run_sql(
        f"SELECT create_geohash_index('latitude_test', 'lat', 'lon', "
        f"{GEOHASH_PRECISION});"
    )
    # S2 side: yb_geospatial_s2's create_spatial_index() builds the
    # latitude_test_s2_index mapping table + s2_auto_index trigger. We
    # disable the S2 trigger for bulk load (each row would otherwise fire
    # an extra INSERT into the mapping table); we'll re-enable it after the
    # bulk-fill step below.
    run_sql("SELECT create_spatial_index('latitude_test', 'geom', 'id');")
    run_sql("ALTER TABLE latitude_test DISABLE TRIGGER trg_s2_latitude_test;")

    # geohash_candidates() now lives in the c_geohash extension itself
    # (signature: (table_name, geom, min_prec, max_prec, max_cells)). It
    # drives one BETWEEN range scan per adaptive cover cell; mirrors
    # yb_geospatial_s2's spatial_candidates_v2().

    # PL/pgSQL helper for S2 candidate lookup. Same shape as the extension's
    # built-in spatial_candidates(), but uses the 4-arg ST_S2Covering so we
    # can pass a real max_cells (the legacy 3-arg hardcodes max_cells=8).
    run_sql("""
        CREATE OR REPLACE FUNCTION spatial_candidates_v2(
            p_table_name text,
            p_query_geom geometry,
            p_min_level  int,
            p_max_level  int,
            p_max_cells  int
        ) RETURNS SETOF int8
        LANGUAGE plpgsql AS $$
        DECLARE
            idx_table text := p_table_name || '_s2_index';
            query_cells int8[];
            cell int8;
            range_min int8;
            range_max int8;
            ancestors int8[];
            cur int8;
            lsb int8;
            new_lsb int8;
            stop_lsb int8 := 1::int8 << (2 * (30 - 4));
        BEGIN
            query_cells := ST_S2Covering(
                p_query_geom, p_min_level, p_max_level, p_max_cells);
            FOR i IN 1..coalesce(array_length(query_cells, 1), 0) LOOP
                cell := query_cells[i];
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
                    idx_table, idx_table
                ) USING range_min, range_max, ancestors;
            END LOOP;
        END;
        $$;
    """)

    # 4. Generate synthetic data
    # We generate POINTS_PER_LAT_PER_LON points around each (band_lat, lon)
    # combination. The same `band_lat` value is used for all longitudes in a
    # band — the longitude isn't a "band marker" in the schema; the bench
    # just queries at known centers within the band.
    print("[3/6] generating synthetic points...")
    rng = random.Random(42)
    csv_path = tempfile.NamedTemporaryFile(
        mode="w", suffix=".csv", delete=False, newline="").name
    t0 = time.time()
    total = 0
    with open(csv_path, "w", newline="") as fh:
        writer = csv.writer(fh, delimiter="|")
        for band_lat in LATITUDES:
            for center_lon in LONGITUDES:
                pts = gen_uniform_points(band_lat, center_lon,
                                         NEIGHBORHOOD_KM,
                                         POINTS_PER_LAT_PER_LON, rng)
                for (lat, lon) in pts:
                    writer.writerow([band_lat, lat, lon])
                    total += 1
    print(f"      generated {total} rows in {time.time()-t0:.1f}s "
          f"({csv_path})")

    # 5. Stage + insert with geohash + geom computed in SQL
    print("[4/6] loading via staging table + computing geohash10/geom...")
    run_sql("""
        CREATE TEMP TABLE _staging (
            band_lat double precision,
            lat      double precision,
            lon      double precision
        );
    """)
    # Use a separate ysqlsh \copy because COPY FROM STDIN via -c is awkward.
    copy_proc = subprocess.run(
        [YSQL, "-h", HOST, "-p", PORT, "-U", USER, "-v", "ON_ERROR_STOP=1",
         "-X", "-d", DB,
         "-c", (f"\\copy _staging(band_lat,lat,lon) "
                f"FROM '{csv_path}' WITH (FORMAT csv, DELIMITER '|')")],
        check=False, capture_output=True, text=True)
    if copy_proc.returncode != 0:
        # Note: TEMP TABLE created above died with the previous ysqlsh
        # process. We need to use a real table.
        print("      \\copy needs same connection as TEMP TABLE; "
              "switching to permanent staging.")
    # Switch to a real (non-temp) staging table so COPY in a separate
    # ysqlsh invocation can write to it.
    run_sql("""
        DROP TABLE IF EXISTS _staging;
        CREATE TABLE _staging (
            band_lat double precision,
            lat      double precision,
            lon      double precision
        );
    """)
    t0 = time.time()
    subprocess.run(
        [YSQL, "-h", HOST, "-p", PORT, "-U", USER, "-v", "ON_ERROR_STOP=1",
         "-X", "-d", DB,
         "-c", (f"\\copy _staging(band_lat,lat,lon) "
                f"FROM '{csv_path}' WITH (FORMAT csv, DELIMITER '|')")],
        check=True)
    print(f"      copied to _staging in {time.time()-t0:.1f}s")

    t0 = time.time()
    # geohash10 is filled by the BEFORE INSERT trigger installed by
    # create_geohash_index() above; we only INSERT (band_lat, lat, lon, geom).
    run_sql("""
        INSERT INTO latitude_test (band_lat, lat, lon, geom)
        SELECT band_lat, lat, lon,
               ST_SetSRID(ST_MakePoint(lon, lat), 4326)
        FROM _staging;
    """)
    run_sql("DROP TABLE _staging;")
    print(f"      moved into latitude_test in {time.time()-t0:.1f}s")

    # 6. Bulk-build the S2 mapping
    print("[5/6] building S2 mapping (bulk, trigger disabled)...")
    t0 = time.time()
    run_sql(f"""
        INSERT INTO latitude_test_s2_index (id, s2_cell)
        SELECT id,
               unnest(ST_S2Covering(geom,
                                    {S2_INDEX_MIN_LEVEL},
                                    {S2_INDEX_MAX_LEVEL},
                                    1000000))
          FROM latitude_test
         WHERE geom IS NOT NULL
        ON CONFLICT DO NOTHING;
    """)
    run_sql("ALTER TABLE latitude_test ENABLE TRIGGER trg_s2_latitude_test;")
    print(f"      done in {time.time()-t0:.1f}s")

    # Final verification
    print("[6/6] verifying counts...")
    res = run_sql("""
        SELECT 'latitude_test'           AS tbl, count(*) FROM latitude_test
        UNION ALL
        SELECT 'latitude_test_s2_index',          count(*)
          FROM latitude_test_s2_index;
    """, fetch=True)
    print(res.stdout)
    print("Setup complete.")
    os.unlink(csv_path)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as e:
        print("SQL error:", file=sys.stderr)
        if e.stderr:
            print(e.stderr.decode() if isinstance(e.stderr, bytes)
                  else e.stderr, file=sys.stderr)
        sys.exit(1)
