#!/usr/bin/env python3
"""
LEVEL-LADDER sweep at the equator -- CELLS + OVER-FETCH.

Holds latitude fixed at 0 (zero shape distortion, gh cells are square) and
varies the rectangle half-width across a fine geometric ladder. For each
(side, scheme) we record:

  * cells       -- the cover cell count
  * candidates  -- the number of distinct table rows the index lookup returns
                   (i.e., before any lat/lon recheck)
  * true_hits   -- the number of rows that actually fall in the query
                   rectangle (computed once per side from the lat/lon
                   filter alone)
  * over_fetch  = candidates / true_hits

over_fetch tells you how loose the cover is. A value of 1.0 means perfect
recall with no false positives at the index layer. Higher values mean the
index returned many rows that the recheck has to throw away.

Schemes under test:
  * gh @ each fixed precision in [3..7]
       (the full set of fixed precisions the C extension exposes)
  * S2 @ max_cells = 8        (extension default for spatial_candidates)
  * S2 @ max_cells = 64       (larger budget for context)

The argument this is set up to test:
  > Within any fixed cell-count budget B, S2 produces a tight cover
  > (low over_fetch) at every query scale. Geohash cannot -- picking a
  > precision fixes BOTH cells and cell size, so any single precision
  > is tight at exactly one query scale and pays either over-budget
  > cells (precision too fine) or excessive over-fetch (precision too
  > coarse) at every other scale.

Run at lat=0, lon=7.0 (the existing "unlucky" longitude -- not a clean
fraction of any geohash grid step) so neither side benefits from grid
alignment.

Output:
  * markdown table to stdout (cells + over_fetch per scheme)
  * CSV under distortion_test/results/run_<ts>/levelladder_sweep.csv
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
SIDE_KM = [3, 4, 5, 7, 10, 14, 20, 28, 40, 56, 80, 112, 160, 224]
EARTH_R_KM = 6371.0088

GH_PRECISIONS = [3, 4, 5, 6, 7]
S2_MIN_LEVEL = 4
S2_MAX_LEVEL = 16
S2_BUDGETS = [8, 64]

# Skip the candidates query for any scheme whose cell count exceeds this --
# at gh-7 / 224 km the cover is 45 k cells and each cell becomes a
# sequential BETWEEN scan inside geohash_candidates, so the query takes
# minutes. cells_only=True still records the cell count.
CANDIDATES_CELL_CAP = 5000

# Per-DB-query timeout (seconds). If a candidate-count query exceeds it
# we record None for over_fetch.
QUERY_TIMEOUT_S = 90


def rect_bbox_deg(lat, lon, side_km):
    """Centered axis-aligned square of `side_km` half-width."""
    a = side_km / EARTH_R_KM
    phi = math.radians(lat)
    dlat = math.degrees(a)
    dlon = math.degrees(math.asin(math.sin(a) / math.cos(phi)))
    return (lon - dlon, lat - dlat, lon + dlon, lat + dlat)


def run_one(sql, timeout_s=QUERY_TIMEOUT_S):
    args = [YSQL, "-h", HOST, "-p", PORT, "-U", USER,
            "-v", "ON_ERROR_STOP=1", "-X", "-d", DB, "-t", "-A", "-c", sql]
    try:
        out = subprocess.run(args, check=True, capture_output=True,
                             text=True, timeout=timeout_s)
        return out.stdout.strip()
    except subprocess.TimeoutExpired:
        return None


def true_hits(side):
    mn_lon, mn_lat, mx_lon, mx_lat = rect_bbox_deg(LAT, LON, side)
    sql = (f"SELECT count(*) FROM latitude_test t "
           f"WHERE t.lon BETWEEN {mn_lon} AND {mx_lon} "
           f"AND t.lat BETWEEN {mn_lat} AND {mx_lat};")
    return int(run_one(sql))


def gh_cells(side, p):
    mn_lon, mn_lat, mx_lon, mx_lat = rect_bbox_deg(LAT, LON, side)
    sql = (f"SELECT COALESCE(array_length(c_geohash_l10_ranges_merged("
           f"{mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, {p}), 1), 0) / 2;")
    out = run_one(sql)
    return int(out) if out else 0


def gh_candidates(side, p):
    mn_lon, mn_lat, mx_lon, mx_lat = rect_bbox_deg(LAT, LON, side)
    sql = (f"SELECT count(*) FROM latitude_test t WHERE t.id = ANY(ARRAY("
           f"SELECT geohash_candidates('latitude_test', "
           f"{mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, {p})));")
    out = run_one(sql)
    return int(out) if out is not None and out != "" else None


def s2_cells(side, max_cells):
    mn_lon, mn_lat, mx_lon, mx_lat = rect_bbox_deg(LAT, LON, side)
    sql = (f"SELECT COALESCE(array_length(ST_S2Covering("
           f"ST_MakeEnvelope({mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, 4326), "
           f"{S2_MIN_LEVEL}, {S2_MAX_LEVEL}, {max_cells}), 1), 0);")
    out = run_one(sql)
    return int(out) if out else 0


def s2_candidates(side, max_cells):
    mn_lon, mn_lat, mx_lon, mx_lat = rect_bbox_deg(LAT, LON, side)
    sql = (f"SELECT count(*) FROM latitude_test t WHERE t.id = ANY(ARRAY("
           f"SELECT spatial_candidates_v2('latitude_test', "
           f"ST_MakeEnvelope({mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, 4326), "
           f"{S2_MIN_LEVEL}, {S2_MAX_LEVEL}, {max_cells})));")
    out = run_one(sql)
    return int(out) if out is not None and out != "" else None


def fmt_of(over):
    if over is None:
        return "skip"
    if over >= 1000:
        return f"{over:>5.0f}x"
    return f"{over:>5.1f}x"


def main():
    print("# LEVEL-LADDER sweep with OVER-FETCH (lat=0)")
    print(f"# anchor      : (lat={LAT}, lon={LON})")
    print(f"# sides (km)  : {SIDE_KM}    (half-width)")
    print(f"# gh precs    : {GH_PRECISIONS}")
    print(f"# s2 budgets  : {S2_BUDGETS}")
    print(f"# candidates skip if cells > {CANDIDATES_CELL_CAP} "
          f"(cover too big, query too slow)\n")

    here = os.path.dirname(os.path.realpath(__file__))
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir = os.path.join(here, "results", f"run_{ts}")
    os.makedirs(run_dir, exist_ok=True)
    csv_path = os.path.join(run_dir, "levelladder_sweep.csv")
    csv_fp = open(csv_path, "w", newline="")
    csv_w = csv.writer(csv_fp)
    cols = ["side_km", "true_hits"]
    for p in GH_PRECISIONS:
        cols += [f"gh{p}_cells", f"gh{p}_cands", f"gh{p}_overfetch"]
    for b in S2_BUDGETS:
        cols += [f"s2_{b}_cells", f"s2_{b}_cands", f"s2_{b}_overfetch"]
    csv_w.writerow(cols)
    print(f"# CSV -> {csv_path}\n")

    # Compact two-line header per scheme: cells / over_fetch.
    line1 = ["    side", "true_hits"]
    line2 = ["       ", "         "]
    for p in GH_PRECISIONS:
        line1 += [f"gh{p}_cells", f"gh{p}_over"]
        line2 += ["    ", "    "]
    for b in S2_BUDGETS:
        line1 += [f"s2@{b}_cells", f"s2@{b}_over"]
        line2 += ["    ", "    "]
    print("| " + " | ".join(f"{c:>10}" for c in line1) + " |")
    print("|" + "|".join(["-"*12] * len(line1)) + "|")

    for side in SIDE_KM:
        th = true_hits(side)
        row_csv = [side, th]
        row_print = [f"{side:>3}km", f"{th:>9}"]

        for p in GH_PRECISIONS:
            c = gh_cells(side, p)
            cand = (gh_candidates(side, p)
                    if c <= CANDIDATES_CELL_CAP else None)
            over = (cand / th) if (cand is not None and th > 0) else None
            row_csv += [c, cand, f"{over:.4f}" if over is not None else ""]
            row_print += [f"{c:>10}", fmt_of(over)]

        for b in S2_BUDGETS:
            c = s2_cells(side, b)
            cand = (s2_candidates(side, b)
                    if c <= CANDIDATES_CELL_CAP else None)
            over = (cand / th) if (cand is not None and th > 0) else None
            row_csv += [c, cand, f"{over:.4f}" if over is not None else ""]
            row_print += [f"{c:>10}", fmt_of(over)]

        print("| " + " | ".join(f"{c:>10}" for c in row_print) + " |",
              flush=True)
        csv_w.writerow(row_csv)
        csv_fp.flush()

    csv_fp.close()
    print(f"\n# CSV written to {csv_path}")


if __name__ == "__main__":
    main()
