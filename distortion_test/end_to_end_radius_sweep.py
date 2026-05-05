#!/usr/bin/env python3
"""
Sweep latitude × radius × longitude to capture realistic geohash alignment.

Why each dimension:
  * latitude: the structural distortion factor (cell count scales 1/cos(lat))
  * radius:   even at fixed lat, the bbox-width-in-p7-cells determines whether
              the merge collapses cleanly. r=50 km is exceptionally lucky
              (656 = 82×8 cells). r=25 and r=75 are both NOT 8-divisible —
              representative of typical production query sizes.
  * longitude: the bbox start position in p7 cells is alignment-sensitive.
              Lucky positions are at multiples of 90°/2^k. We pick 4
              longitudes (17, 31, 53, 71) that are NOT clean fractions of
              90° — all empirically in the unlucky regime (~6,000+ cells).

The matrix is deliberately chosen to live entirely in the unlucky regime —
that's what production looks like; lucky geometries are vanishingly rare.

Output:
  * markdown table to stdout: median latency per (lat, radius) across all
    longitudes, plus min..max range
  * CSV with one row per (lat, radius, lon) for full inspection
"""
import csv
import datetime
import math
import os
import statistics
import subprocess
import time

YB_BIN = "/net/dev-server-te-yenchou/share/code/yugabyte-db/build/latest/postgres/bin"
YSQL = os.path.join(YB_BIN, "ysqlsh")
HOST = "127.0.0.1"
PORT = "5433"
USER = "yugabyte"
DB = "lat_bench"

LATITUDES = [0, 30, 60, 80, 87]
RADII_KM = [25, 75]
LONGITUDES = [7.0, 31.0, 55.0, 79.0]  # match end_to_end_setup.py
# Spacing 24° — picked to exceed the cluster-overlap threshold at the
# highest test latitude. At lat=87°, each 100 km synthetic cluster spans
# ~17° in lon and an r=75 query bbox is ~26° wide; ≥22° spacing keeps
# neighboring clusters out of each other's queries.
#
# Lucky-alignment check (must be unlucky at all (lat, r) combinations):
#   lon=7°  : verified unlucky at lat=0° (r=25 → 3114, r=75 → 8442)
#   lon=31° : verified unlucky at lat=0° (r=25 → 3442, r=75 → 9372)
#   lon=55° : NOT yet verified — please run the predictor before bench
#             (it might be a multiple of 90/2^k).
#   lon=79° : verified unlucky at lat=0° (r=25 → 3114, r=75 → 9426)
#
# Avoid {23, 67, 71} — those land in lucky regimes for at least one radius.
EARTH_R_KM = 6371.0088
GH_QUERY_PRECISION = 7
S2_MIN_LEVEL = 4
S2_MAX_LEVEL = 16
S2_MAX_CELLS = 1_000_000
RUNS_TOTAL = 5  # 1 warmup + 4 measurements (median of 4)


def disk_bbox_deg(lat, lon, r_km):
    a = r_km / EARTH_R_KM
    phi = math.radians(lat)
    dlat = math.degrees(a)
    dlon = math.degrees(math.asin(math.sin(a) / math.cos(phi)))
    return (lon - dlon, lat - dlat, lon + dlon, lat + dlat)


def run_one(sql):
    args = [YSQL, "-h", HOST, "-p", PORT, "-U", USER,
            "-v", "ON_ERROR_STOP=1", "-X", "-d", DB, "-t", "-A", "-c", sql]
    t0 = time.time()
    out = subprocess.run(args, check=True, capture_output=True, text=True)
    return time.time() - t0, out.stdout.strip()


def gh_query(lat, lon, r_km):
    mn_lon, mn_lat, mx_lon, mx_lat = disk_bbox_deg(lat, lon, r_km)
    return (
        f"SELECT count(*) FROM latitude_test t "
        f"WHERE t.id = ANY(ARRAY("
        f"SELECT geohash_candidates('latitude_test', "
        f"{mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, "
        f"{GH_QUERY_PRECISION}))) "
        f"AND ST_Distance(t.geom::geography, "
        f"ST_SetSRID(ST_MakePoint({lon}, {lat}), 4326)::geography) <= "
        f"{r_km * 1000.0};"
    )


def s2_query(lat, lon, r_km):
    return (
        f"SELECT count(*) FROM latitude_test t "
        f"WHERE t.id = ANY(ARRAY("
        f"SELECT spatial_candidates_v2('latitude_test', "
        f"ST_Buffer(ST_SetSRID(ST_MakePoint({lon},{lat}),4326)::geography, "
        f"{r_km * 1000.0})::geometry, "
        f"{S2_MIN_LEVEL}, {S2_MAX_LEVEL}, {S2_MAX_CELLS}))) "
        f"AND ST_Distance(t.geom::geography, "
        f"ST_SetSRID(ST_MakePoint({lon}, {lat}), 4326)::geography) <= "
        f"{r_km * 1000.0};"
    )


def predicted_gh(lat, lon, r_km):
    mn_lon, mn_lat, mx_lon, mx_lat = disk_bbox_deg(lat, lon, r_km)
    sql = (f"SELECT array_length(c_geohash_l10_ranges_merged("
           f"{mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, "
           f"{GH_QUERY_PRECISION}), 1) / 2;")
    _, out = run_one(sql)
    return int(out)


def predicted_s2(lat, lon, r_km):
    sql = (f"SELECT array_length(ST_S2Covering("
           f"ST_Buffer(ST_SetSRID(ST_MakePoint({lon},{lat}),4326)::geography, "
           f"{r_km * 1000.0})::geometry, "
           f"{S2_MIN_LEVEL}, {S2_MAX_LEVEL}, {S2_MAX_CELLS}), 1);")
    _, out = run_one(sql)
    return int(out)


def measure(query_sql):
    times = []
    hits = None
    for run in range(RUNS_TOTAL):
        t, out = run_one(query_sql)
        hits = int(out)
        if run > 0:
            times.append(t)
    return statistics.median(times) * 1000, hits


def main():
    print(f"# Latitude × Radius × Longitude sweep")
    print(f"# Latitudes : {LATITUDES}")
    print(f"# Radii (km): {RADII_KM}")
    print(f"# Longitudes: {LONGITUDES}")
    print(f"# {RUNS_TOTAL-1} measurement(s) per (lat, r, lon, scheme), "
          f"median reported")
    print(f"# One row per (lat, r, lon) — no aggregation across longitudes.\n")

    # CSV output goes to distortion_test/results/ (in .gitignore).
    here = os.path.dirname(os.path.realpath(__file__))
    results_dir = os.path.join(here, "results")
    os.makedirs(results_dir, exist_ok=True)
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    csv_path = os.path.join(results_dir, f"radius_sweep_{ts}.csv")
    csv_fp = open(csv_path, "w", newline="")
    csv_w = csv.writer(csv_fp)
    csv_w.writerow([
        "lat", "lon", "radius_km",
        "gh_cells", "gh_hits", "gh_ms",
        "s2_cells", "s2_hits", "s2_ms",
        "cells_gh_over_s2", "time_gh_over_s2",
    ])
    print(f"# CSV → {csv_path}\n")

    print(f"| {'lat':>3} | {'r':>4} | {'lon':>5} | "
          f"{'gh cells':>8} | {'gh hits':>7} | {'gh ms':>8} | "
          f"{'s2 cells':>8} | {'s2 hits':>7} | {'s2 ms':>8} | "
          f"{'cells gh/s2':>11} | {'time gh/s2':>10} |")
    print("|" + "|".join(["-"*5, "-"*6, "-"*7, "-"*10, "-"*9, "-"*10,
                          "-"*10, "-"*9, "-"*10, "-"*13, "-"*12]) + "|")

    for lat in LATITUDES:
        for r in RADII_KM:
            for lon in LONGITUDES:
                gh_predicted = predicted_gh(lat, lon, r)
                s2_predicted = predicted_s2(lat, lon, r)
                gh_ms, gh_hits = measure(gh_query(lat, lon, r))
                s2_ms, s2_hits = measure(s2_query(lat, lon, r))
                cells_ratio = (gh_predicted / s2_predicted
                               if s2_predicted else 0)
                time_ratio = gh_ms / s2_ms

                print(f"| {lat:>3} | {r:>3}km | {lon:>5.1f} | "
                      f"{gh_predicted:>8} | {gh_hits:>7} | "
                      f"{gh_ms:>7.0f}ms | "
                      f"{s2_predicted:>8} | {s2_hits:>7} | "
                      f"{s2_ms:>7.0f}ms | "
                      f"{cells_ratio:>10.1f}× | {time_ratio:>9.1f}× |",
                      flush=True)
                csv_w.writerow([
                    lat, lon, r,
                    gh_predicted, gh_hits, f"{gh_ms:.1f}",
                    s2_predicted, s2_hits, f"{s2_ms:.1f}",
                    f"{cells_ratio:.3f}", f"{time_ratio:.3f}",
                ])
                csv_fp.flush()
            print(f"|{'--':>5}|{'-':->6}|{'-':->7}|{'-':->10}|{'-':->9}|"
                  f"{'-':->10}|{'-':->10}|{'-':->9}|{'-':->10}|"
                  f"{'-':->13}|{'-':->12}|")

    csv_fp.close()
    print(f"\n# CSV written to {csv_path}")


if __name__ == "__main__":
    main()
