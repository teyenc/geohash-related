#!/usr/bin/env python3
"""
RECTANGLE-query variant of the radius sweep.

Same lat × size × longitude matrix as end_to_end_radius_sweep_three_way.py,
but the QUERY SHAPE is an axis-aligned rectangle (centered on the anchor
point) instead of a disk. This exposes the inverse asymmetry: on
rectangles, gh's bbox-merge is the optimal cover (no boundary-band tax,
no corners to skip), while S2's coverer still has to walk a 4-ary tree
along the rectangle's perimeter. Geohash should win here, the way S2
wins on disks.

Output:
  * markdown table to stdout
  * CSV under distortion_test/results/run_<ts>/rect_sweep_three_way.csv
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

LATITUDES   = [0, 30, 60, 80, 87]
SIDE_KM     = [25, 75]                # half-width of the square in km
LONGITUDES  = [7.0]                   # single lon (sweep matrix kept tight)
EARTH_R_KM  = 6371.0088
GH_QUERY_PRECISION = 7
S2_MIN_LEVEL = 4
S2_MAX_LEVEL = 16
S2_MAX_CELLS = 1_000_000
# NOTE: gh_skip used to call int64 cgeo_spatial_candidates(geom, min, max,
# max_cells). That API was removed when c_geohash went text-only. With only
# bbox-cover available, "skip" produces the same cells as "bbox" for any
# axis-aligned envelope (which is all this script generates), so gh_skip is
# now an alias for gh_bbox. See module-level NOTE in the radius variant.
RUNS_TOTAL  = 2  # 1 warmup + 1 measured


def rect_bbox_deg(lat, lon, side_km):
    """Centered axis-aligned square of `side_km` half-width.
    Same physical coverage as the disk sweep's bbox at the same `r_km`."""
    a = side_km / EARTH_R_KM
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


def gh_bbox_query(lat, lon, side):
    mn_lon, mn_lat, mx_lon, mx_lat = rect_bbox_deg(lat, lon, side)
    return (
        f"SELECT count(*) FROM latitude_test t "
        f"WHERE t.id = ANY(ARRAY("
        f"SELECT geohash_candidates('latitude_test', "
        f"{mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, "
        f"{GH_QUERY_PRECISION}))) "
        f"AND t.lon BETWEEN {mn_lon} AND {mx_lon} "
        f"AND t.lat BETWEEN {mn_lat} AND {mx_lat};"
    )


def gh_skip_query(lat, lon, side):
    """Deprecated alias for gh_bbox_query — see module-level NOTE.
    The int64 c_geohash_cover_geometry path that this used to call no longer
    exists. For axis-aligned rectangles (all this script tests) it would have
    produced the same cells as gh_bbox anyway."""
    return gh_bbox_query(lat, lon, side)


def s2_query(lat, lon, side):
    mn_lon, mn_lat, mx_lon, mx_lat = rect_bbox_deg(lat, lon, side)
    return (
        f"SELECT count(*) FROM latitude_test t "
        f"WHERE t.id = ANY(ARRAY("
        f"SELECT spatial_candidates_v2('latitude_test', "
        f"ST_MakeEnvelope({mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, 4326), "
        f"{S2_MIN_LEVEL}, {S2_MAX_LEVEL}, {S2_MAX_CELLS}))) "
        f"AND t.lon BETWEEN {mn_lon} AND {mx_lon} "
        f"AND t.lat BETWEEN {mn_lat} AND {mx_lat};"
    )


def predicted_gh_bbox(lat, lon, side):
    mn_lon, mn_lat, mx_lon, mx_lat = rect_bbox_deg(lat, lon, side)
    sql = (f"SELECT array_length(c_geohash_l10_ranges_merged("
           f"{mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, "
           f"{GH_QUERY_PRECISION}), 1) / 2;")
    _, out = run_one(sql)
    return int(out) if out else 0


def predicted_gh_skip(lat, lon, side):
    """Same as predicted_gh_bbox — see module-level NOTE."""
    return predicted_gh_bbox(lat, lon, side)


def predicted_s2(lat, lon, side):
    mn_lon, mn_lat, mx_lon, mx_lat = rect_bbox_deg(lat, lon, side)
    sql = (f"SELECT array_length(ST_S2Covering("
           f"ST_MakeEnvelope({mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, 4326), "
           f"{S2_MIN_LEVEL}, {S2_MAX_LEVEL}, {S2_MAX_CELLS}), 1);")
    _, out = run_one(sql)
    return int(out) if out else 0


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
    print("# Three-way RECTANGLE sweep (geohash should beat S2 here)")
    print(f"# Latitudes : {LATITUDES}")
    print(f"# Sides (km): {SIDE_KM}    (half-width; physical-equivalent to "
          f"disk r in radius_sweep)")
    print(f"# Longitudes: {LONGITUDES}")
    print(f"# {RUNS_TOTAL-1} measurement(s) per (lat, side, lon, scheme), "
          f"median reported\n")

    here = os.path.dirname(os.path.realpath(__file__))
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir = os.path.join(here, "results", f"run_{ts}")
    os.makedirs(run_dir, exist_ok=True)
    csv_path = os.path.join(run_dir, "rect_sweep_three_way.csv")
    csv_fp = open(csv_path, "w", newline="")
    csv_w = csv.writer(csv_fp)
    csv_w.writerow([
        "lat", "lon", "side_km",
        "gh_bbox_cells", "gh_bbox_hits", "gh_bbox_ms",
        "gh_skip_cells", "gh_skip_hits", "gh_skip_ms",
        "s2_cells",      "s2_hits",      "s2_ms",
        "ratio_s2_over_gh",
    ])
    print(f"# CSV → {csv_path}\n")

    header = (f"| {'lat':>3} | {'side':>5} | {'lon':>5} | "
              f"{'gh_bbox':>8} | {'gh_skip':>8} | {'s2':>8} | "
              f"{'gh_ms':>6} | {'sk_ms':>6} | {'s2_ms':>6} | "
              f"{'s2/gh':>6} |")
    sep = ("|" + "|".join(["-"*5, "-"*7, "-"*7,
                            "-"*10, "-"*10, "-"*10,
                            "-"*8, "-"*8, "-"*8,
                            "-"*8]) + "|")
    print(header); print(sep)

    for lat in LATITUDES:
        for side in SIDE_KM:
            for lon in LONGITUDES:
                gh_bb_cells = predicted_gh_bbox(lat, lon, side)
                gh_sk_cells = predicted_gh_skip(lat, lon, side)
                s2_cells   = predicted_s2(lat, lon, side)

                gh_bb_ms, gh_bb_hits = measure(gh_bbox_query(lat, lon, side))
                gh_sk_ms, gh_sk_hits = measure(gh_skip_query(lat, lon, side))
                s2_ms,    s2_hits    = measure(s2_query(lat, lon, side))

                ratio_s2_over_gh = (s2_cells / gh_sk_cells
                                    if gh_sk_cells else 0)

                print(f"| {lat:>3} | {side:>3}km | {lon:>5.1f} | "
                      f"{gh_bb_cells:>8} | {gh_sk_cells:>8} | "
                      f"{s2_cells:>8} | "
                      f"{gh_bb_ms:>5.0f}ms | {gh_sk_ms:>5.0f}ms | "
                      f"{s2_ms:>5.0f}ms | "
                      f"{ratio_s2_over_gh:>5.2f}× |", flush=True)
                csv_w.writerow([
                    lat, lon, side,
                    gh_bb_cells, gh_bb_hits, f"{gh_bb_ms:.1f}",
                    gh_sk_cells, gh_sk_hits, f"{gh_sk_ms:.1f}",
                    s2_cells,    s2_hits,    f"{s2_ms:.1f}",
                    f"{ratio_s2_over_gh:.3f}",
                ])
                csv_fp.flush()
            print(sep)

    csv_fp.close()
    print(f"\n# CSV written to {csv_path}")


if __name__ == "__main__":
    main()
