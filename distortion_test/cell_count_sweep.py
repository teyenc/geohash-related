#!/usr/bin/env python3
"""
Cell-count sweep across latitude + longitude — pure-geometry measurement.

For each (lat, lon) sample point, builds a fixed real-area envelope and
asks each engine's adaptive top-down coverer how many cells it emits to
cover that envelope. NO data scanned, NO DocDB RPCs measured — this is
the algorithm's intrinsic distortion shape, not the realized DB cost.

Sister script: latency_sweep.py
  * latency_sweep.py    -- DB-side latency + RPCs with my_mapdata loaded
  * cell_count_sweep.py -- raw cell counts from the cover function alone

The two share an x-axis (LATITUDES/LONGITUDES/SIDE_KM live in
sweep_config.py) so their charts can be put side by side.

DB routing (c_geohash and yb_geospatial_s2 no longer coexist in one DB):
  c_geohash_cover_geometry(...)  -> bench_cgeo
  ST_S2Covering(...)             -> bench_s2

Both engines run their adaptive top-down coverer (S2's classic algorithm:
priority queue + 1-level look-ahead, cells terminate when fully contained
in the bbox or at max_level). max_cells is effectively unbounded — the
cap is on the LEAF LEVEL, not the cell budget — so the result is the
exact minimal merged cover at the matched leaf level.

CLI:
  --skip-gh    skip the c_geohash side (only measure S2)
  --skip-s2    skip the S2 side (only measure c_geohash)

Output:
  * markdown table to stdout (raw per (lat, lon) plus median summary)
  * CSV under results/run_<ts>/cell_count.csv
"""
import argparse
import csv
import datetime
import math
import os
import statistics
import subprocess
import sys

from sweep_config import CELL_COUNT_LATITUDES as LATITUDES, LONGITUDES, SIDE_KM

YB_BIN = "/net/dev-server-te-yenchou/share/code/yugabyte-db/build/latest/postgres/bin"
YSQL = os.path.join(YB_BIN, "ysqlsh")
HOST = "127.0.0.1"
PORT = "5433"
USER = "yugabyte"

# Two DBs because the two extensions can't coexist (both register the
# `geometry` type). Each call routes to whichever DB hosts its function.
GH_DB = "bench_cgeo"   # has c_geohash extension + c_geohash_cover_geometry
S2_DB = "bench_s2"     # has yb_geospatial_s2 + ST_S2Covering

# Adaptive coverer level ranges. Both engines subdivide from the coarse
# min level down to a leaf level chosen so cells are ~150 m at the
# equator (apples-to-apples cell size):
#   gh-7  cells: 0.001373 x 0.001373 deg = 152 m x 152 m at the equator
#   S2-L16 avg edge ~ 142 m globally
#
# min_prec/min_level start at the COARSEST sensible level so the adaptive
# coverer has maximum freedom to merge — that's the right intent for
# measuring distortion-shape; latency_sweep.py uses a tighter range that
# matches what's actually indexed at load time.
GH_MIN_PREC,   GH_MAX_PREC   = 1, 7
S2_MIN_LEVEL,  S2_MAX_LEVEL  = 4, 16

# Effectively unbounded — the LEAF LEVEL caps the cover, not a cell-count
# budget. The adaptive coverer will subdivide every non-fully-contained
# cell down to the leaf level.
MAX_CELLS = 1_000_000

EARTH_R_KM = 6371.0088


def rect_bbox_deg(lat, lon, side_km):
    """(lon_min, lat_min, lon_max, lat_max) for an envelope spanning
    `side_km` km on each side of (lat, lon) on the spheroid."""
    a = side_km / EARTH_R_KM
    phi = math.radians(lat)
    dlat = math.degrees(a)
    cos_phi = math.cos(phi)
    if cos_phi < 1e-9:
        dlon = 180.0
    else:
        dlon = math.degrees(math.asin(min(1.0, math.sin(a) / cos_phi)))
    return (lon - dlon, lat - dlat, lon + dlon, lat + dlat)


def run_one(db, sql):
    """Run a single SQL in the named DB, return stripped scalar output."""
    args = [YSQL, "-h", HOST, "-p", PORT, "-U", USER,
            "-v", "ON_ERROR_STOP=1", "-X", "-d", db, "-t", "-A", "-c", sql]
    out = subprocess.run(args, check=True, capture_output=True, text=True)
    return out.stdout.strip()


def gh_cells(lat, lon):
    """c_geohash adaptive cover: returns number of (min10, max10) pairs."""
    mn_lon, mn_lat, mx_lon, mx_lat = rect_bbox_deg(lat, lon, SIDE_KM)
    sql = (f"SELECT COALESCE(array_length(c_geohash_cover_geometry("
           f"ST_MakeEnvelope({mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, 4326), "
           f"{GH_MIN_PREC}, {GH_MAX_PREC}, {MAX_CELLS}), 1), 0) / 2;")
    out = run_one(GH_DB, sql)
    return int(out) if out else 0


def s2_cells(lat, lon):
    """S2 adaptive cover: returns number of cell IDs emitted."""
    mn_lon, mn_lat, mx_lon, mx_lat = rect_bbox_deg(lat, lon, SIDE_KM)
    sql = (f"SELECT COALESCE(array_length(ST_S2Covering("
           f"ST_MakeEnvelope({mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, 4326), "
           f"{S2_MIN_LEVEL}, {S2_MAX_LEVEL}, {MAX_CELLS}), 1), 0);")
    out = run_one(S2_DB, sql)
    return int(out) if out else 0


def main():
    parser = argparse.ArgumentParser(
        description=("Cell-count sweep across latitudes: c_geohash vs S2 "
                     "adaptive coverer. Pure geometry, no DB queries."))
    parser.add_argument(
        '--skip-gh', action='store_true',
        help="Skip the c_geohash side (only measure S2).")
    parser.add_argument(
        '--skip-s2', action='store_true',
        help="Skip the S2 side (only measure c_geohash).")
    args = parser.parse_args()
    if args.skip_gh and args.skip_s2:
        print("ERROR: --skip-gh and --skip-s2 together leaves nothing to run.",
              file=sys.stderr)
        sys.exit(2)
    do_gh = not args.skip_gh
    do_s2 = not args.skip_s2

    print("# Cell-count sweep across latitude (with 4-longitude sampling)")
    print(f"# latitudes   : {LATITUDES}    (from sweep_config.py)")
    print(f"# longitudes  : {LONGITUDES}   (from sweep_config.py)")
    print(f"# query side  : {SIDE_KM} km half-width  ({2*SIDE_KM} km box)")
    if do_gh:
        print(f"# gh range    : precision {GH_MIN_PREC}..{GH_MAX_PREC} "
              f"(leaf gh-{GH_MAX_PREC} = ~152 m cells at the equator)")
    if do_s2:
        print(f"# S2 range    : level {S2_MIN_LEVEL}..{S2_MAX_LEVEL} "
              f"(leaf S2-L{S2_MAX_LEVEL} = ~142 m cells globally)")
    print(f"# max_cells   : {MAX_CELLS}  (effectively unbounded)")
    print(f"# engines     : "
          f"{'gh' if do_gh else ''}"
          f"{', ' if do_gh and do_s2 else ''}"
          f"{'s2' if do_s2 else ''}")
    if do_gh: print(f"# gh DB       : {GH_DB}")
    if do_s2: print(f"# s2 DB       : {S2_DB}")
    print()

    here = os.path.dirname(os.path.realpath(__file__))
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir = os.path.join(here, "results", f"run_{ts}")
    os.makedirs(run_dir, exist_ok=True)
    csv_path = os.path.join(run_dir, "cell_count.csv")
    csv_fp = open(csv_path, "w", newline="")
    csv_w = csv.writer(csv_fp)
    # Always write both columns so the schema is stable across runs;
    # skipped engines just leave their column blank for that row.
    csv_w.writerow(["lat", "lon", "gh_cells", "s2_cells"])
    print(f"# CSV -> {csv_path}\n")

    cols = ['lat', 'lon']
    if do_gh: cols.append('gh')
    if do_s2: cols.append('s2')
    print("| " + " | ".join(f"{c:>5}" for c in cols) + " |")
    print("|" + "|".join(["-"*7]*len(cols)) + "|")

    per_lat_gh = {lat: [] for lat in LATITUDES}
    per_lat_s2 = {lat: [] for lat in LATITUDES}

    for lat in LATITUDES:
        for lon in LONGITUDES:
            gh = gh_cells(lat, lon) if do_gh else ''
            s2 = s2_cells(lat, lon) if do_s2 else ''
            row_cells = [str(lat) + '°', f"{lon:.1f}"]
            if do_gh: row_cells.append(str(gh))
            if do_s2: row_cells.append(str(s2))
            print("| " + " | ".join(f"{c:>5}" for c in row_cells) + " |",
                  flush=True)
            csv_w.writerow([lat, lon, gh, s2])
            csv_fp.flush()
            if do_gh: per_lat_gh[lat].append(gh)
            if do_s2: per_lat_s2[lat].append(s2)
        print("|" + "|".join(["-"*7]*len(cols)) + "|")

    csv_fp.close()
    print(f"\n# CSV written to {csv_path}\n")

    # Summary: median across longitudes per latitude, plus growth ratio
    # vs the lat=LATITUDES[0] baseline.
    print("# Summary -- median across longitudes per latitude:\n")
    summary_cols = ['lat']
    if do_gh: summary_cols += ['gh med', 'gh /lat0']
    if do_s2: summary_cols += ['s2 med', 's2 /lat0']
    print("| " + " | ".join(f"{c:>8}" for c in summary_cols) + " |")
    print("|" + "|".join(["-"*10]*len(summary_cols)) + "|")

    gh_baseline = (statistics.median(per_lat_gh[LATITUDES[0]])
                   if do_gh and per_lat_gh[LATITUDES[0]] else 1) or 1
    s2_baseline = (statistics.median(per_lat_s2[LATITUDES[0]])
                   if do_s2 and per_lat_s2[LATITUDES[0]] else 1) or 1

    for lat in LATITUDES:
        cells = [f"{lat}°"]
        if do_gh:
            gh_m = statistics.median(per_lat_gh[lat]) if per_lat_gh[lat] else 0
            cells += [f"{gh_m:.0f}", f"{gh_m/gh_baseline:.2f}x"]
        if do_s2:
            s2_m = statistics.median(per_lat_s2[lat]) if per_lat_s2[lat] else 0
            cells += [f"{s2_m:.0f}", f"{s2_m/s2_baseline:.2f}x"]
        print("| " + " | ".join(f"{c:>8}" for c in cells) + " |")


if __name__ == "__main__":
    main()
