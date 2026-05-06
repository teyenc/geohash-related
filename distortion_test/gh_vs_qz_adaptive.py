#!/usr/bin/env python3
"""
LEG 3 -- gh vs qz cell-count comparison at the equator.

Holds latitude FIXED at 0 (zero distortion -- strips out leg 1) and
sweeps query size and anchor longitude. For each (lon, side) the
adaptive coverer is run with effectively unbounded max_cells (= exact
minimal cover at the matched leaf level).

Structural argument: with curve, algorithm, and matched cell shape all
held constant, the gh-vs-qz cell-count gap is purely the effect of
tree branching factor. gh's 32-child rollup fires less often than
qz's 4-child rollup, so gh leaves more boundary cells un-merged.

Matched-shape range: gh precision 2..6 maps to qz level 5..15 in
bit-count terms (each gh prec = 5 bits, each qz level = 2 bits;
gh-2 = 10 bits = qz-L5; gh-6 = 30 bits = qz-L15). At gh's even
precisions (2, 4, 6) the cells are exactly 2:1 (lon:lat), matching
qz's intrinsic 2:1 shape at every level. At gh's odd precisions
(3, 5) gh cells are square -- a small implementation difference
that doesn't affect the structural conclusion at the level of
tree-arity comparison.

Sweep design:
  * 4 "unlucky" longitudes -- avoids cherry-picked grid alignment.
  * 7 query half-widths spanning 50x in scale -- covers the full
    range of "between-precision" sizes where gh's lumpy 32-step
    subdivision struggles.
  * 4 x 7 = 28 (lon, size) data points per system.

Output:
  * raw markdown table per (lon, size) to stdout
  * aggregate-across-lons summary (median + min/max band per size)
  * CSV under distortion_test/results/run_<ts>/gh_vs_qz.csv
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

LAT = 0
# Sweep dimension 1: anchor longitude. 4 lons spaced 24 deg apart, none
# at clean fractions of the geohash grid (so neither system gets a
# grid-aligned bbox by luck).
LONGITUDES = [7.0, 31.0, 55.0, 79.0]
# Sweep dimension 2: query half-width.
SIDE_KM    = [3, 5, 10, 20, 40, 80, 160]

# Matched-shape level/precision range (both systems can drill from a
# coarse seed down to the same physical leaf cell).
GH_MIN_PREC,   GH_MAX_PREC   = 2, 6      # 10 bits to 30 bits
QZ_MIN_LEVEL,  QZ_MAX_LEVEL  = 5, 15     # same bit range

# Effectively unbounded budget so the coverer emits the exact merged
# cover at the matched leaf level.
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


def gh_cells(lon, side):
    mn_lon, mn_lat, mx_lon, mx_lat = rect_bbox_deg(LAT, lon, side)
    sql = (f"SELECT COALESCE(array_length(c_geohash_cover_geometry("
           f"ST_MakeEnvelope({mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, 4326), "
           f"{GH_MIN_PREC}, {GH_MAX_PREC}, {MAX_CELLS}), 1), 0) / 2;")
    out = run_one(sql)
    return int(out) if out else 0


def qz_cells(lon, side):
    mn_lon, mn_lat, mx_lon, mx_lat = rect_bbox_deg(LAT, lon, side)
    sql = (f"SELECT COALESCE(array_length(c_qz_cover_geometry_str("
           f"ST_MakeEnvelope({mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, 4326), "
           f"{QZ_MIN_LEVEL}, {QZ_MAX_LEVEL}, {MAX_CELLS}), 1), 0) / 2;")
    out = run_one(sql)
    return int(out) if out else 0


def main():
    print("# LEG 3 -- gh vs qz cell-count comparison (lat=0, no distortion)")
    print(f"# longitudes  : {LONGITUDES}")
    print(f"# sides (km)  : {SIDE_KM}")
    print(f"# gh range    : precision {GH_MIN_PREC}..{GH_MAX_PREC} "
          f"(matched-shape leaf at gh-{GH_MAX_PREC} = 1.22 km x 0.61 km)")
    print(f"# qz range    : level {QZ_MIN_LEVEL}..{QZ_MAX_LEVEL} "
          f"(matched-shape leaf at qz-L{QZ_MAX_LEVEL} = same cells)")
    print(f"# max_cells   : {MAX_CELLS} (effectively unbounded -- exact cover)")
    print()

    here = os.path.dirname(os.path.realpath(__file__))
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir = os.path.join(here, "results", f"run_{ts}")
    os.makedirs(run_dir, exist_ok=True)
    csv_path = os.path.join(run_dir, "gh_vs_qz.csv")
    csv_fp = open(csv_path, "w", newline="")
    csv_w = csv.writer(csv_fp)
    csv_w.writerow(["lon", "side_km", "gh_cells", "qz_cells", "gh_over_qz"])
    print(f"# CSV -> {csv_path}\n")

    # Part 1: per (lon, side) raw data
    print("## Part 1 -- Raw cell counts per (lon, size)\n")
    print(f"| {'lon':>5} | {'side':>5} | {'gh':>6} | {'qz':>6} | "
          f"{'gh/qz':>7} |")
    print("|" + "|".join(["-"*7]*5) + "|")

    rows_per_side = {s: {"gh": [], "qz": [], "ratios": []} for s in SIDE_KM}
    for lon in LONGITUDES:
        for side in SIDE_KM:
            gh = gh_cells(lon, side)
            qz = qz_cells(lon, side)
            ratio = (gh / qz) if qz > 0 else float("inf")
            print(f"| {lon:>5.1f} | {side:>3}km | {gh:>6} | {qz:>6} | "
                  f"{ratio:>5.2f}x |", flush=True)
            csv_w.writerow([lon, side, gh, qz, f"{ratio:.4f}"])
            csv_fp.flush()
            rows_per_side[side]["gh"].append(gh)
            rows_per_side[side]["qz"].append(qz)
            rows_per_side[side]["ratios"].append(ratio)
        print("|" + "|".join(["-"*7]*5) + "|")

    # Part 2: aggregate across lons per side
    print("\n## Part 2 -- Aggregate across longitudes (per query size)\n")
    print(f"| {'side':>5} | "
          f"{'gh med':>7} | {'gh min':>7} | {'gh max':>7} | "
          f"{'qz med':>7} | {'qz min':>7} | {'qz max':>7} | "
          f"{'gh/qz med':>9} |")
    print("|" + "|".join(["-"*7]*8) + "|")

    for side in SIDE_KM:
        gh_arr = rows_per_side[side]["gh"]
        qz_arr = rows_per_side[side]["qz"]
        rt_arr = rows_per_side[side]["ratios"]

        print(f"| {side:>3}km | "
              f"{statistics.median(gh_arr):>7.0f} | "
              f"{min(gh_arr):>7} | {max(gh_arr):>7} | "
              f"{statistics.median(qz_arr):>7.0f} | "
              f"{min(qz_arr):>7} | {max(qz_arr):>7} | "
              f"{statistics.median(rt_arr):>7.2f}x  |")

    csv_fp.close()
    print(f"\n# CSV written to {csv_path}")


if __name__ == "__main__":
    main()
