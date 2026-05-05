#!/usr/bin/env python3
"""
Phase 4 harness: run end-to-end latitude-distortion benchmark.

For each test latitude:
  1. Compute the disk's lat/lon bbox.
  2. Get predicted cell counts from c_geohash_l10_ranges_merged (geohash side)
     and ST_S2Covering with 4-arg max_cells (S2 side).
  3. Run each query 4 times, drop the first (warmup), take median of 3.
  4. Capture actual hit counts (should be ~12,500 within 50 km regardless of
     latitude, since data is uniform 100 km neighborhood per band).

Output: one markdown-style row per latitude, comparing geohash (current C
extension + new c_geohash_l10_ranges_merged + geohash_candidates helper)
against S2 (yb_geospatial_s2 with our new 4-arg ST_S2Covering overload +
spatial_candidates_v2 helper).

Both schemes use:
  - one production-realistic index column (geohash p10 / S2 mapping table)
  - server-side PL/pgSQL helper to issue one B-tree range scan per cell
  - ST_Distance + 50_000 m for the second-stage distance filter
    (NOT ST_DWithin — it's broken in the geography signature, returns
    true regardless of distance.)
"""
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

LATITUDES = [0, 30, 45, 60, 70, 80, 85, 87, 89]
RADIUS_KM = 50.0
EARTH_R_KM = 6371.0088

# Geohash side
GH_QUERY_PRECISION = 7

# S2 side (4-arg overload)
S2_MIN_LEVEL = 4
S2_MAX_LEVEL = 16
S2_MAX_CELLS = 1_000_000

# Bench cadence
RUNS_TOTAL = 4   # 1 warmup + 3 measurements


def disk_bbox_deg(lat, lon, r_km):
    a = r_km / EARTH_R_KM
    phi = math.radians(lat)
    dlat = math.degrees(a)
    dlon = math.degrees(math.asin(math.sin(a) / math.cos(phi)))
    return (lon - dlon, lat - dlat, lon + dlon, lat + dlat)


def run_one(sql, capture=True):
    args = [YSQL, "-h", HOST, "-p", PORT, "-U", USER,
            "-v", "ON_ERROR_STOP=1", "-X", "-d", DB, "-t", "-A", "-c", sql]
    t0 = time.time()
    out = subprocess.run(args, check=True, capture_output=True, text=True)
    elapsed = time.time() - t0
    return elapsed, out.stdout.strip() if capture else None


def geohash_count_query(lat):
    mn_lon, mn_lat, mx_lon, mx_lat = disk_bbox_deg(lat, 0.0, RADIUS_KM)
    return (
        f"SELECT count(*) FROM latitude_test t "
        f"WHERE t.id = ANY(ARRAY("
        f"SELECT geohash_candidates('latitude_test', "
        f"{mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, "
        f"{GH_QUERY_PRECISION}))) "
        f"AND ST_Distance(t.geom::geography, "
        f"ST_SetSRID(ST_MakePoint(0, {lat}), 4326)::geography) <= "
        f"{RADIUS_KM * 1000.0};"
    )


def s2_count_query(lat):
    return (
        f"SELECT count(*) FROM latitude_test t "
        f"WHERE t.id = ANY(ARRAY("
        f"SELECT spatial_candidates_v2('latitude_test', "
        f"ST_Buffer(ST_SetSRID(ST_MakePoint(0,{lat}),4326)::geography, "
        f"{RADIUS_KM * 1000.0})::geometry, "
        f"{S2_MIN_LEVEL}, {S2_MAX_LEVEL}, {S2_MAX_CELLS}))) "
        f"AND ST_Distance(t.geom::geography, "
        f"ST_SetSRID(ST_MakePoint(0, {lat}), 4326)::geography) <= "
        f"{RADIUS_KM * 1000.0};"
    )


def predicted_geohash_cells(lat):
    """Number of merged geohash prefix ranges (= B-tree range scans)."""
    mn_lon, mn_lat, mx_lon, mx_lat = disk_bbox_deg(lat, 0.0, RADIUS_KM)
    sql = (f"SELECT array_length(c_geohash_l10_ranges_merged("
           f"{mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, "
           f"{GH_QUERY_PRECISION}), 1) / 2;")
    _, out = run_one(sql)
    return int(out)


def predicted_s2_cells(lat):
    """Number of S2 query cells (= B-tree range scans on s2_cell column)."""
    sql = (f"SELECT array_length(ST_S2Covering("
           f"ST_Buffer(ST_SetSRID(ST_MakePoint(0,{lat}),4326)::geography, "
           f"{RADIUS_KM * 1000.0})::geometry, "
           f"{S2_MIN_LEVEL}, {S2_MAX_LEVEL}, {S2_MAX_CELLS}), 1);")
    _, out = run_one(sql)
    return int(out)


def main():
    print(f"# End-to-end latency: geohash vs S2, 50 km disk")
    print(f"# {RUNS_TOTAL-1} measurements per (latitude, scheme), median reported")
    print(f"# geohash query precision: {GH_QUERY_PRECISION}  (storage at p10)")
    print(f"# S2 levels: {S2_MIN_LEVEL}..{S2_MAX_LEVEL}, max_cells={S2_MAX_CELLS}\n")

    print(f"| {'lat':>4} | {'gh cells':>8} | {'gh hits':>7} | "
          f"{'gh ms':>8} | {'s2 cells':>8} | {'s2 hits':>7} | "
          f"{'s2 ms':>8} | {'gh/s2':>5} |")
    print("|" + "|".join(["-"*6, "-"*10, "-"*9, "-"*10, "-"*10,
                          "-"*9, "-"*10, "-"*7]) + "|")

    for lat in LATITUDES:
        gh_predicted = predicted_geohash_cells(lat)
        s2_predicted = predicted_s2_cells(lat)

        gh_q = geohash_count_query(lat)
        s2_q = s2_count_query(lat)

        gh_times = []
        for run in range(RUNS_TOTAL):
            elapsed, out = run_one(gh_q)
            gh_hits = int(out)
            if run > 0:  # drop warmup
                gh_times.append(elapsed)

        s2_times = []
        for run in range(RUNS_TOTAL):
            elapsed, out = run_one(s2_q)
            s2_hits = int(out)
            if run > 0:
                s2_times.append(elapsed)

        gh_ms = statistics.median(gh_times) * 1000
        s2_ms = statistics.median(s2_times) * 1000
        ratio = gh_ms / s2_ms

        print(f"| {lat:>4} | {gh_predicted:>8} | {gh_hits:>7} | "
              f"{gh_ms:>7.0f}ms | {s2_predicted:>8} | {s2_hits:>7} | "
              f"{s2_ms:>7.0f}ms | {ratio:>4.1f}× |", flush=True)


if __name__ == "__main__":
    main()
