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

DB routing (c_geohash and yb_geospatial_s2 don't coexist in one DB; qz
piggybacks on c_geohash's geometry type and lives in its own bench_qz):
  c_geohash_cover_geometry(...)        -> bench_cgeo  (gh side)
  c_qz_cover_geometry_str(...)         -> bench_qz    (qz side)
  ST_S2Covering(...)                   -> bench_s2    (s2 side)

All three engines run their adaptive top-down coverer (S2's classic
algorithm: priority queue + 1-level look-ahead, cells terminate when
fully contained in the bbox or at max_level). max_cells is effectively
unbounded — the cap is on the LEAF LEVEL, not the cell budget — so the
result is the exact minimal merged cover at the matched leaf level.

Three-way comparison:
  gh   : 32-ary tree, Z-order curve
  qz   : 4-ary tree,  Z-order curve
  s2   : 4-ary tree,  Hilbert curve
gh vs qz isolates branching factor; qz vs s2 isolates the curve. The
Moon-Jagadish-Faloutsos-Saltz paper predicts qz / s2 ~ 1.85 (i.e. S2
emits 43-48% fewer cells than QZ) for matched-leaf-size queries.

CLI:
  --skip-gh    skip the c_geohash side
  --skip-qz    skip the c_quadtree_z side
  --skip-s2    skip the S2 side

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

# Three DBs because the geometry-providing extensions don't coexist.
# c_quadtree_z piggybacks on c_geohash's geometry type in bench_qz.
GH_DB = "bench_cgeo"   # has c_geohash         + c_geohash_cover_geometry
QZ_DB = "bench_qz"     # has c_quadtree_z      + c_qz_cover_geometry_str
S2_DB = "bench_s2"     # has yb_geospatial_s2  + ST_S2Covering

# Adaptive coverer level ranges. All three engines subdivide from the
# coarsest sensible level (lots of merge freedom — that's the right
# intent for measuring distortion-shape) down to a leaf level chosen
# so cells are ~150 m at the equator (apples-to-apples cell size):
#   gh-7   : 0.001373° × 0.001373° = 152 m × 152 m at the equator
#   qz-18  : 0.00137°  × 0.000687° = 153 m × 76 m  at the equator (cell area ~11.7k m²)
#   S2-L16 : avg edge ~ 142 m globally                        (cell area ~20.2k m²)
#
# qz-18 cells are SMALLER (in area) than S2-16 — flipping the cell-size
# confound. Now any qz advantage in cluster count is purely the curve
# effect (Z-order vs Hilbert). Paper predicts qz / s2 ~ 1.85 at low
# latitudes for matched leaf size.
GH_MIN_PREC,   GH_MAX_PREC   = 1, 7
QZ_MIN_LEVEL,  QZ_MAX_LEVEL  = 1, 18
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


def qz_cells(lat, lon):
    """c_quadtree_z adaptive cover: returns number of (min30, max30) pairs."""
    mn_lon, mn_lat, mx_lon, mx_lat = rect_bbox_deg(lat, lon, SIDE_KM)
    sql = (f"SELECT COALESCE(array_length(c_qz_cover_geometry_str("
           f"ST_MakeEnvelope({mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, 4326), "
           f"{QZ_MIN_LEVEL}, {QZ_MAX_LEVEL}, {MAX_CELLS}), 1), 0) / 2;")
    out = run_one(QZ_DB, sql)
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
        description=("Cell-count sweep across latitudes. Default engines: "
                     "c_geohash (gh) and S2 — the main 2-way comparison. "
                     "Use --with-qz to add the c_quadtree_z side for the "
                     "Hilbert-vs-Z-order isolation experiment. Pure "
                     "geometry, no DB queries."))
    parser.add_argument(
        '--skip-gh', action='store_true',
        help="Drop the c_geohash side.")
    parser.add_argument(
        '--with-qz', action='store_true',
        help=("Include the c_quadtree_z (qz) side. Off by default — qz is "
              "the auxiliary 4-ary-tree + Z-order engine for isolating the "
              "branching-factor effect against gh (32-ary, also Z-order) "
              "and the curve effect against s2 (4-ary, Hilbert)."))
    parser.add_argument(
        '--skip-s2', action='store_true',
        help="Drop the S2 side.")
    args = parser.parse_args()
    do_gh = not args.skip_gh
    do_qz = args.with_qz                 # opt-in
    do_s2 = not args.skip_s2
    if not (do_gh or do_qz or do_s2):
        print("ERROR: skipping all engines leaves nothing to run.",
              file=sys.stderr)
        sys.exit(2)

    print("# Cell-count sweep across latitude (with 4-longitude sampling)")
    print(f"# latitudes   : {LATITUDES}    (from sweep_config.py)")
    print(f"# longitudes  : {LONGITUDES}   (from sweep_config.py)")
    print(f"# query side  : {SIDE_KM} km half-width  ({2*SIDE_KM} km box)")
    if do_gh:
        print(f"# gh range    : precision {GH_MIN_PREC}..{GH_MAX_PREC} "
              f"(leaf gh-{GH_MAX_PREC} = ~152 m cells at the equator)")
    if do_qz:
        print(f"# qz range    : level {QZ_MIN_LEVEL}..{QZ_MAX_LEVEL} "
              f"(leaf qz-L{QZ_MAX_LEVEL} = ~153 m × 76 m cells at the equator)")
    if do_s2:
        print(f"# S2 range    : level {S2_MIN_LEVEL}..{S2_MAX_LEVEL} "
              f"(leaf S2-L{S2_MAX_LEVEL} = ~142 m cells globally)")
    print(f"# max_cells   : {MAX_CELLS}  (effectively unbounded)")
    active = []
    if do_gh: active.append('gh')
    if do_qz: active.append('qz')
    if do_s2: active.append('s2')
    print(f"# engines     : {', '.join(active)}")
    if do_gh: print(f"# gh DB       : {GH_DB}")
    if do_qz: print(f"# qz DB       : {QZ_DB}")
    if do_s2: print(f"# s2 DB       : {S2_DB}")
    print()

    here = os.path.dirname(os.path.realpath(__file__))
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir = os.path.join(here, "results", f"run_{ts}")
    os.makedirs(run_dir, exist_ok=True)
    csv_path = os.path.join(run_dir, "cell_count.csv")
    csv_fp = open(csv_path, "w", newline="")
    csv_w = csv.writer(csv_fp)
    # Always write all three columns so the schema is stable across runs;
    # skipped engines just leave their column blank for that row.
    csv_w.writerow(["lat", "lon", "gh_cells", "qz_cells", "s2_cells"])
    print(f"# CSV -> {csv_path}\n")

    cols = ['lat', 'lon']
    if do_gh: cols.append('gh')
    if do_qz: cols.append('qz')
    if do_s2: cols.append('s2')
    print("| " + " | ".join(f"{c:>5}" for c in cols) + " |")
    print("|" + "|".join(["-"*7]*len(cols)) + "|")

    per_lat_gh = {lat: [] for lat in LATITUDES}
    per_lat_qz = {lat: [] for lat in LATITUDES}
    per_lat_s2 = {lat: [] for lat in LATITUDES}

    for lat in LATITUDES:
        for lon in LONGITUDES:
            gh = gh_cells(lat, lon) if do_gh else ''
            qz = qz_cells(lat, lon) if do_qz else ''
            s2 = s2_cells(lat, lon) if do_s2 else ''
            row_cells = [str(lat) + '°', f"{lon:.1f}"]
            if do_gh: row_cells.append(str(gh))
            if do_qz: row_cells.append(str(qz))
            if do_s2: row_cells.append(str(s2))
            print("| " + " | ".join(f"{c:>5}" for c in row_cells) + " |",
                  flush=True)
            csv_w.writerow([lat, lon, gh, qz, s2])
            csv_fp.flush()
            if do_gh: per_lat_gh[lat].append(gh)
            if do_qz: per_lat_qz[lat].append(qz)
            if do_s2: per_lat_s2[lat].append(s2)
        print("|" + "|".join(["-"*7]*len(cols)) + "|")

    csv_fp.close()
    print(f"\n# CSV written to {csv_path}\n")

    # Summary: median across longitudes per latitude, plus growth ratio
    # vs the lat=LATITUDES[0] baseline.
    print("# Summary -- median across longitudes per latitude:\n")
    summary_cols = ['lat']
    if do_gh: summary_cols += ['gh med', 'gh /lat0']
    if do_qz: summary_cols += ['qz med', 'qz /lat0']
    if do_s2: summary_cols += ['s2 med', 's2 /lat0']
    print("| " + " | ".join(f"{c:>8}" for c in summary_cols) + " |")
    print("|" + "|".join(["-"*10]*len(summary_cols)) + "|")

    gh_baseline = (statistics.median(per_lat_gh[LATITUDES[0]])
                   if do_gh and per_lat_gh[LATITUDES[0]] else 1) or 1
    qz_baseline = (statistics.median(per_lat_qz[LATITUDES[0]])
                   if do_qz and per_lat_qz[LATITUDES[0]] else 1) or 1
    s2_baseline = (statistics.median(per_lat_s2[LATITUDES[0]])
                   if do_s2 and per_lat_s2[LATITUDES[0]] else 1) or 1

    for lat in LATITUDES:
        cells = [f"{lat}°"]
        if do_gh:
            gh_m = statistics.median(per_lat_gh[lat]) if per_lat_gh[lat] else 0
            cells += [f"{gh_m:.0f}", f"{gh_m/gh_baseline:.2f}x"]
        if do_qz:
            qz_m = statistics.median(per_lat_qz[lat]) if per_lat_qz[lat] else 0
            cells += [f"{qz_m:.0f}", f"{qz_m/qz_baseline:.2f}x"]
        if do_s2:
            s2_m = statistics.median(per_lat_s2[lat]) if per_lat_s2[lat] else 0
            cells += [f"{s2_m:.0f}", f"{s2_m/s2_baseline:.2f}x"]
        print("| " + " | ".join(f"{c:>8}" for c in cells) + " |")


if __name__ == "__main__":
    main()
