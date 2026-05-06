#!/usr/bin/env python3
"""
Distortion sweep across latitude + longitude.

ALL systems use the adaptive top-down coverer (S2's algorithm: priority
queue + 1-level look-ahead, with cells terminating either at max_level
or when fully contained in the region). max_cells is set effectively
unbounded -- the cap is on the LEAF LEVEL, not the cell count -- so the
result is the exact minimal merged cover at the matched leaf level.

Sweeps latitude (the structural axis -- distortion grows with cos(lat)^-1
for lat/lon-plane systems) and longitude (4 anchors to avoid alignment
luck). For each (lat, lon) the cell count is recorded; aggregation is
done downstream by the plot script (median across the 4 lons per lat).

Output:
  * markdown table to stdout (raw per (lat, lon) plus median summary)
  * CSV under distortion_test/results/run_<ts>/distortion.csv
"""
import csv
import datetime
import math
import os
import statistics
import subprocess

YB_BIN = "/net/dev-server-te-yenchou/share/code/yugabyte-db/build/latest/postgres/bin"
YSQL = os.path.join(YB_BIN, "ysqlsh")
HOST = "127.0.0.1"
PORT = "5433"
USER = "yugabyte"
DB = "lat_bench"

# Sweep dim 1: latitude. Distortion grows with cos(lat)^-1 for lat/lon-plane
# systems (geohash). S2's cube projection sidesteps this. Every 5 deg
# below 80 deg, then dense near the pole where distortion accelerates.
# Stopping at 89 deg to keep per-query work bounded -- at lat=89.9 the
# bbox in degrees would be ~130 deg wide, generating multi-million-cell
# leaf covers that are slow without adding insight.
LATITUDES = [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70,
             75, 80, 82, 84, 85, 86, 87, 88, 89]
# Sweep dim 2: anchor longitude. 4 lons spaced 24 deg apart, none on
# clean fractions of any grid step (no grid-alignment luck).
LONGITUDES = [7.0, 31.0, 55.0, 79.0]

SIDE_KM = 25.0      # half-width = 25 km, so 50 km x 50 km box

# Adaptive coverer level/precision ranges. Both systems subdivide from
# the coarse min level down to the matched leaf level (~150 m cells):
#   gh-7  cells: 0.001373 x 0.001373 deg = 152 m x 152 m  at the equator
#   S2-L16 avg edge ~ 142 m globally
GH_MIN_PREC,   GH_MAX_PREC   = 1, 7
S2_MIN_LEVEL,  S2_MAX_LEVEL  = 4, 16

# max_cells is effectively unbounded -- the LEAF LEVEL caps the cover,
# not a cell-count budget. The adaptive coverer will subdivide every
# non-fully-contained cell down to the leaf level.
MAX_CELLS = 1_000_000

EARTH_R_KM = 6371.0088


def rect_bbox_deg(lat, lon, side_km):
    a = side_km / EARTH_R_KM
    phi = math.radians(lat)
    dlat = math.degrees(a)
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


def gh_cells(lat, lon):
    """gh adaptive top-down: subdivides from gh-1 down to gh-7,
    terminating cells fully contained in the bbox or at the leaf."""
    mn_lon, mn_lat, mx_lon, mx_lat = rect_bbox_deg(lat, lon, SIDE_KM)
    sql = (f"SELECT COALESCE(array_length(c_geohash_cover_geometry("
           f"ST_MakeEnvelope({mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, 4326), "
           f"{GH_MIN_PREC}, {GH_MAX_PREC}, {MAX_CELLS}), 1), 0) / 2;")
    out = run_one(sql)
    return int(out) if out else 0


def s2_cells(lat, lon):
    """S2 adaptive top-down: subdivides from L4 down to L16, terminating
    cells fully contained in the bbox or at the leaf."""
    mn_lon, mn_lat, mx_lon, mx_lat = rect_bbox_deg(lat, lon, SIDE_KM)
    sql = (f"SELECT COALESCE(array_length(ST_S2Covering("
           f"ST_MakeEnvelope({mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, 4326), "
           f"{S2_MIN_LEVEL}, {S2_MAX_LEVEL}, {MAX_CELLS}), 1), 0);")
    out = run_one(sql)
    return int(out) if out else 0


def main():
    print("# Distortion sweep across latitude (with 4-longitude sampling)")
    print(f"# latitudes   : {LATITUDES}")
    print(f"# longitudes  : {LONGITUDES}")
    print(f"# query side  : {SIDE_KM} km half-width  ({2*SIDE_KM} km box)")
    print(f"# gh range    : precision {GH_MIN_PREC}..{GH_MAX_PREC} "
          f"(leaf gh-{GH_MAX_PREC} = ~152 m cells at the equator)")
    print(f"# S2 range    : level {S2_MIN_LEVEL}..{S2_MAX_LEVEL} "
          f"(leaf S2-L{S2_MAX_LEVEL} = ~142 m cells globally)")
    print(f"# max_cells   : {MAX_CELLS}  (effectively unbounded)")
    print()

    here = os.path.dirname(os.path.realpath(__file__))
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir = os.path.join(here, "results", f"run_{ts}")
    os.makedirs(run_dir, exist_ok=True)
    csv_path = os.path.join(run_dir, "distortion.csv")
    csv_fp = open(csv_path, "w", newline="")
    csv_w = csv.writer(csv_fp)
    csv_w.writerow(["lat", "lon", "gh_cells", "s2_cells"])
    print(f"# CSV -> {csv_path}\n")

    print(f"| {'lat':>5} | {'lon':>5} | {'gh':>10} | {'s2':>10} |")
    print("|" + "|".join(["-"*7]*4) + "|")

    per_lat_gh = {lat: [] for lat in LATITUDES}
    per_lat_s2 = {lat: [] for lat in LATITUDES}

    for lat in LATITUDES:
        for lon in LONGITUDES:
            gh = gh_cells(lat, lon)
            s2 = s2_cells(lat, lon)
            print(f"| {lat:>3}°  | {lon:>5.1f} | {gh:>10} | {s2:>10} |",
                  flush=True)
            csv_w.writerow([lat, lon, gh, s2])
            csv_fp.flush()
            per_lat_gh[lat].append(gh)
            per_lat_s2[lat].append(s2)
        print("|" + "|".join(["-"*7]*4) + "|")

    csv_fp.close()
    print(f"\n# CSV written to {csv_path}\n")

    print("# Summary -- median across longitudes per latitude:\n")
    print(f"| {'lat':>5} | {'gh med':>9} | {'s2 med':>9} | "
          f"{'gh /lat0':>9} | {'s2 /lat0':>9} |")
    print("|" + "|".join(["-"*7, "-"*11, "-"*11, "-"*11, "-"*11]) + "|")

    gh_baseline = statistics.median(per_lat_gh[LATITUDES[0]]) or 1
    s2_baseline = statistics.median(per_lat_s2[LATITUDES[0]]) or 1

    for lat in LATITUDES:
        gh_m = statistics.median(per_lat_gh[lat])
        s2_m = statistics.median(per_lat_s2[lat])
        print(f"| {lat:>3}°  | {gh_m:>9.0f} | {s2_m:>9.0f} | "
              f"{gh_m/gh_baseline:>7.2f}x | {s2_m/s2_baseline:>7.2f}x |")


if __name__ == "__main__":
    main()
