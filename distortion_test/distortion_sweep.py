#!/usr/bin/env python3
"""
LEG 1 -- Distortion sweep across latitude.

Holds query size, anchor longitude, and per-system precision/level FIXED.
Sweeps latitude. For each system, reports the cell count produced for the
identical physical-area query at each latitude.

Structural argument: at high latitudes, cos(lat) -> 0 makes geohash's
lat/lon-plane cells pathologically thin in lon, so gh's cell count
balloons toward the pole. S2's cube-projection cells stay roughly
square globally, so its cell count stays bounded.

Each system is compared to ITSELF across latitudes -- the metric is
"# of cells growth ratio" relative to the lat=0 baseline. Cross-system
absolute numbers depend on cell-shape choice (gh-7 cells are square at
152 m, S2-L16 cells are roughly square at ~140 m -- close enough to
compare directly).

Output:
  * markdown table to stdout (cells per latitude per system)
  * CSV under distortion_test/results/run_<ts>/distortion.csv
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

# Sweep dimension: latitude. The whole point.
LATITUDES = [0, 30, 45, 60, 70, 80, 85, 87, 89]

# Fixed dimensions:
LON = 7.0           # "unlucky" anchor (not a clean fraction of any grid step)
SIDE_KM = 25.0      # half-width = 25 km, so 50 km x 50 km box

# Per-system precision/level. Both produce ~150 m cells at lat=0:
#   gh-7: 18 lon bits + 17 lat bits -> 0.001373 deg x 0.001373 deg
#         (square at the equator, ~152 m x 152 m).
#   S2-L16: ~142 m avg edge from S2's kAvgEdge constant.
GH_PRECISION = 7
S2_LEVEL    = 16

# max_cells = effectively infinity so we get the exact merged cover.
MAX_CELLS = 1_000_000

EARTH_R_KM = 6371.0088


def rect_bbox_deg(lat, lon, side_km):
    """Centered axis-aligned square of `side_km` half-width on the sphere."""
    a = side_km / EARTH_R_KM
    phi = math.radians(lat)
    dlat = math.degrees(a)
    # asin guard: at lat>=89.5 the disk wraps the pole; clamp.
    cos_phi = math.cos(phi)
    if cos_phi < 1e-9:
        dlon = 180.0
    else:
        dlon = math.degrees(math.asin(min(1.0, math.sin(a) / cos_phi)))
    return (lon - dlon, lat - dlat, lon + dlon, lat + dlat)


def run_one(sql):
    args = [YSQL, "-h", HOST, "-p", PORT, "-U", USER,
            "-v", "ON_ERROR_STOP=1", "-X", "-d", DB, "-t", "-A", "-c", sql]
    out = subprocess.run(args, check=True, capture_output=True, text=True)
    return out.stdout.strip()


def gh_cells(lat):
    """gh fixed-precision merged cover. Bottom-up sibling merge from prec=7
    leaf collapses up to coarser precisions where complete 32-child blocks
    fit inside the bbox."""
    mn_lon, mn_lat, mx_lon, mx_lat = rect_bbox_deg(lat, LON, SIDE_KM)
    sql = (f"SELECT COALESCE(array_length(c_geohash_l10_ranges_merged("
           f"{mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, {GH_PRECISION}), 1), 0) "
           f"/ 2;")
    out = run_one(sql)
    return int(out) if out else 0


def s2_cells(lat):
    """S2 fixed-level cover (min_level == max_level), with effectively
    unbounded max_cells so the coverer emits the exact set of L16 cells
    intersecting the query envelope."""
    mn_lon, mn_lat, mx_lon, mx_lat = rect_bbox_deg(lat, LON, SIDE_KM)
    sql = (f"SELECT COALESCE(array_length(ST_S2Covering("
           f"ST_MakeEnvelope({mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, 4326), "
           f"{S2_LEVEL}, {S2_LEVEL}, {MAX_CELLS}), 1), 0);")
    out = run_one(sql)
    return int(out) if out else 0


def main():
    print("# LEG 1 -- Distortion sweep across latitude")
    print(f"# anchor      : (lat=<sweep>, lon={LON})")
    print(f"# query side  : {SIDE_KM} km half-width  ({2*SIDE_KM} km box)")
    print(f"# gh precision: {GH_PRECISION}  (~152 m cells at the equator)")
    print(f"# S2 level    : {S2_LEVEL}  (~142 m cells globally)")
    print(f"# max_cells   : {MAX_CELLS}  (effectively unbounded -- exact cover)")
    print()

    here = os.path.dirname(os.path.realpath(__file__))
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir = os.path.join(here, "results", f"run_{ts}")
    os.makedirs(run_dir, exist_ok=True)
    csv_path = os.path.join(run_dir, "distortion.csv")
    csv_fp = open(csv_path, "w", newline="")
    csv_w = csv.writer(csv_fp)
    csv_w.writerow(["lat", "gh_cells", "s2_cells",
                    "gh_ratio_vs_lat0", "s2_ratio_vs_lat0"])
    print(f"# CSV -> {csv_path}\n")

    print(f"| {'lat':>5} | {'gh cells':>10} | {'gh /lat0':>9} | "
          f"{'s2 cells':>10} | {'s2 /lat0':>9} |")
    print("|" + "|".join(["-"*7, "-"*12, "-"*11, "-"*12, "-"*11]) + "|")

    gh_baseline = None
    s2_baseline = None
    for lat in LATITUDES:
        gh = gh_cells(lat)
        s2 = s2_cells(lat)
        if gh_baseline is None:
            gh_baseline = gh if gh > 0 else 1
            s2_baseline = s2 if s2 > 0 else 1
        gh_ratio = gh / gh_baseline
        s2_ratio = s2 / s2_baseline

        print(f"| {lat:>3}°  | {gh:>10} | {gh_ratio:>7.2f}x | "
              f"{s2:>10} | {s2_ratio:>7.2f}x |", flush=True)
        csv_w.writerow([lat, gh, s2, f"{gh_ratio:.4f}", f"{s2_ratio:.4f}"])
        csv_fp.flush()

    csv_fp.close()
    print(f"\n# CSV written to {csv_path}")


if __name__ == "__main__":
    main()
