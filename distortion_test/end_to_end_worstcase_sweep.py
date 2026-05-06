#!/usr/bin/env python3
"""
WORST-CASE size sweep at the equator -- CELLS ONLY, fast.

Picks 4 query half-widths that fall *maximally far* from any geohash
precision -- specifically, the geometric mean between adjacent gh
precisions, where both parent and child precisions are sqrt(32) =~5.7x
off in linear cell size.

For each worst-case side we report cells under:
  * gh @ parent precision (cells too BIG -- expect few cells, large
                            over-fetch which we are NOT measuring here)
  * gh @ child precision  (cells too SMALL -- expect many cells)
  * gh @ p=7 with merge   (the existing benchmark default)
  * S2 max_cells = 8      (extension default, adaptive level-mixing)
  * S2 max_cells = 64     (larger budget for context)

This is cell-count only -- no DB measurement. Each cell number is one
ysqlsh call to a pure C function, no table touched.
"""
import csv
import datetime
import math
import os
import subprocess

YB_BIN = "/net/dev-server-te-yenchou/share/code/yugabyte-db/build/latest/postgres/bin"
YSQL = os.path.join(YB_BIN, "ysqlsh")
HOST = "127.0.0.1"
PORT = "5433"
USER = "yugabyte"
DB = "lat_bench"

LAT = 0
LON = 7.0
EARTH_R_KM = 6371.0088

# (half_width_km, parent_p, child_p, label) tuples. half_width_km is the
# geometric mean of the two precisions' linear cell sizes at the equator,
# so both parent and child are ~5.7x off in linear dim -- maximally bad
# for gh's discrete precision menu.
WORST_CASES = [
    (   0.36, 6, 7, "between gh-6 (0.86 km) and gh-7 (0.15 km)"),
    (   2.05, 5, 6, "between gh-5 (4.9 km)  and gh-6 (0.86 km)"),
    (  11.6,  4, 5, "between gh-4 (27.5 km) and gh-5 (4.9 km)"),
    (  65.0,  3, 4, "between gh-3 (156 km)  and gh-4 (27.5 km)"),
]

S2_BUDGETS = [8, 64]
S2_MIN_LEVEL = 4
S2_MAX_LEVEL = 18  # one level deeper than 16 so the smallest worst-case
                    # (~360 m) doesn't get clipped by the level cap


def rect_bbox_deg(lat, lon, side_km):
    a = side_km / EARTH_R_KM
    phi = math.radians(lat)
    dlat = math.degrees(a)
    dlon = math.degrees(math.asin(math.sin(a) / math.cos(phi)))
    return (lon - dlon, lat - dlat, lon + dlon, lat + dlat)


def run_one(sql):
    args = [YSQL, "-h", HOST, "-p", PORT, "-U", USER,
            "-v", "ON_ERROR_STOP=1", "-X", "-d", DB, "-t", "-A", "-c", sql]
    out = subprocess.run(args, check=True, capture_output=True, text=True)
    return out.stdout.strip()


def predicted(side):
    mn_lon, mn_lat, mx_lon, mx_lat = rect_bbox_deg(LAT, LON, side)
    return mn_lon, mn_lat, mx_lon, mx_lat


def gh_cells(side, p):
    mn_lon, mn_lat, mx_lon, mx_lat = predicted(side)
    sql = (f"SELECT COALESCE(array_length(c_geohash_l10_ranges_merged("
           f"{mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, {p}), 1), 0) / 2;")
    return int(run_one(sql))


def s2_cells(side, max_cells):
    mn_lon, mn_lat, mx_lon, mx_lat = predicted(side)
    sql = (f"SELECT COALESCE(array_length(ST_S2Covering("
           f"ST_MakeEnvelope({mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, 4326), "
           f"{S2_MIN_LEVEL}, {S2_MAX_LEVEL}, {max_cells}), 1), 0);")
    return int(run_one(sql))


def main():
    print("# WORST-CASE size sweep (lat=0, no distortion, lon=7°)")
    print(f"# 4 sizes chosen as geom-mean between adjacent gh precisions")
    print(f"# -- both parent and child are sqrt(32) ~= 5.7x off in linear\n")

    here = os.path.dirname(os.path.realpath(__file__))
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir = os.path.join(here, "results", f"run_{ts}")
    os.makedirs(run_dir, exist_ok=True)
    csv_path = os.path.join(run_dir, "worstcase_sweep.csv")
    csv_fp = open(csv_path, "w", newline="")
    csv_w = csv.writer(csv_fp)
    csv_w.writerow(["side_km", "parent_p", "child_p",
                    "gh_parent", "gh_child", "gh_p7_merge",
                    "s2_8", "s2_64", "label"])
    print(f"# CSV -> {csv_path}\n")

    print(f"| {'side':>9} | {'gh@parent':>15} | {'gh@child':>14} | "
          f"{'gh@p7+merge':>11} | {'s2@8':>5} | {'s2@64':>6} | label")
    print(f"|{'-'*11}|{'-'*17}|{'-'*16}|{'-'*13}|{'-'*7}|{'-'*8}|"
          f"{'-'*48}")

    for side, parent_p, child_p, label in WORST_CASES:
        gh_par = gh_cells(side, parent_p)
        gh_chi = gh_cells(side, child_p)
        gh_p7  = gh_cells(side, 7)
        s2_8   = s2_cells(side, 8)
        s2_64  = s2_cells(side, 64)

        ratio_p_to_c = (gh_chi / gh_par) if gh_par else float("inf")

        print(f"| {side:>5.2f} km | "
              f"p{parent_p}: {gh_par:>10} | "
              f"p{child_p}: {gh_chi:>9} | "
              f"{gh_p7:>11} | "
              f"{s2_8:>5} | {s2_64:>6} | "
              f"{label}")

        csv_w.writerow([side, parent_p, child_p,
                        gh_par, gh_chi, gh_p7,
                        s2_8, s2_64, label])
        csv_fp.flush()

    csv_fp.close()
    print(f"\n# CSV written to {csv_path}")


if __name__ == "__main__":
    main()
