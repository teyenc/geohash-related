#!/usr/bin/env python3
"""
Three-way adaptive coverer comparison: gh vs qz vs S2.

All three systems now use the SAME algorithm:
  - top-down subdivision via priority queue
  - 1-level look-ahead before queueing
  - (level, num_children, num_terminals) priority
  - max_cells budget enforcement
  - GEOS predicates for MayIntersect / Contains (gh, qz) or S2's
    native predicates (S2)

The only differences across the three are:
  - tree branching factor:  gh = 32     qz = 4    S2 = 4
  - space-filling curve:    gh = Z      qz = Z    S2 = Hilbert

So:
  gh vs qz isolates BRANCHING FACTOR (curve held to Z)
  qz vs S2 isolates CURVE (branching factor held to 4)

For each query we also report total cell area / query area (analytic
over-fetch) so we can see cover tightness alongside cell count.
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
SIDE_KM = [3, 5, 10, 20, 40, 80, 160]
EARTH_R_KM = 6371.0088

BUDGETS = [8, 32, 128]  # max_cells values to test

# Level/precision ranges -- matched-shape cap so the deepest cell each
# system can produce is physically identical between gh and qz:
#   gh-2 / qz-L5  : 11.25 deg x 5.625 deg cells (1252 km x 626 km)
#   gh-6 / qz-L15 : 0.011 deg x 0.0055 deg cells (1.22 km x 0.61 km)
# In bit-count terms (each gh prec = 5 bits, each qz level = 2 bits):
#   gh-2 = 10 bits, qz-L5  = 10 bits  --> matched at the coarse end
#   gh-6 = 30 bits, qz-L15 = 30 bits  --> matched at the fine end
# S2 uses the same bit-count range for parity, but S2 cells stay
# roughly square (cube-face projection) -- that's intrinsic.
GH_MIN_PREC,   GH_MAX_PREC   = 2, 6
QZ_MIN_LEVEL,  QZ_MAX_LEVEL  = 5, 15
S2_MIN_LEVEL,  S2_MAX_LEVEL  = 5, 15

# Cell linear (km) at each gh precision and qz/S2 level. Used to compute
# analytic cover area for an over-fetch estimate.
GH_CELL_LINEAR_KM = {
    1: 5008.0, 2: 885.0, 3: 156.0, 4: 27.5, 5: 4.9, 6: 0.86, 7: 0.152,
}
# qz cells at level L: 360/2^L deg lon * 180/2^L deg lat at equator.
def qz_cell_area_km2(level):
    side = 1 << level
    lon_km = 360.0 / side * 111.0
    lat_km = 180.0 / side * 111.0
    return lon_km * lat_km

# S2 average cell area at level L: 4*pi*R^2 / (6 * 4^L) km^2
S2_TOTAL_AREA_KM2 = 4 * math.pi * EARTH_R_KM ** 2
def s2_cell_area_km2(level):
    return S2_TOTAL_AREA_KM2 / (6 * (4 ** level))


def rect_bbox_deg(lat, lon, side_km):
    a = side_km / EARTH_R_KM
    phi = math.radians(lat)
    dlat = math.degrees(a)
    dlon = math.degrees(math.asin(math.sin(a) / math.cos(phi)))
    return (lon - dlon, lat - dlat, lon + dlon, lat + dlat)


def query_area_km2(side_km):
    return (2 * side_km) ** 2


def run_one(sql):
    args = [YSQL, "-h", HOST, "-p", PORT, "-U", USER,
            "-v", "ON_ERROR_STOP=1", "-X", "-d", DB, "-t", "-A", "-c", sql]
    out = subprocess.run(args, check=True, capture_output=True, text=True)
    return out.stdout.strip()


def gh_count_and_area(side, max_cells):
    """Returns (num_cells, total_cover_area_km2) for gh adaptive cover."""
    mn_lon, mn_lat, mx_lon, mx_lat = rect_bbox_deg(LAT, LON, side)
    sql = (f"SELECT c_geohash_cover_geometry(ST_MakeEnvelope("
           f"{mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, 4326), "
           f"{GH_MIN_PREC}, {GH_MAX_PREC}, {max_cells});")
    out = run_one(sql)
    if not out.startswith("{") or not out.endswith("}"):
        return 0, 0.0
    body = out[1:-1].strip()
    if not body:
        return 0, 0.0
    parts = body.split(",")
    if len(parts) % 2 != 0:
        return 0, 0.0
    num_cells = len(parts) // 2
    total_area = 0.0
    # Cell area per gh precision -- accounts for the alternating
    # square / 2:1 cell shape (gh-2 is 11.25 x 5.625 deg, etc.).
    # Geometric cell areas in km^2 at the equator:
    GH_CELL_AREA = {
        1: 5008.0 ** 2,        # 45 deg x 45 deg cells
        2: 1252.0 * 626.0,     # 11.25 x 5.625 deg
        3: 156.0 ** 2,         # 1.41 x 1.41 deg
        4: 39.0 * 19.0,        # 0.352 x 0.176 deg
        5: 4.9 ** 2,           # 0.044 x 0.044 deg
        6: 1.22 * 0.61,        # 0.011 x 0.0055 deg
        7: 0.152 ** 2,         # 0.00137 x 0.00137 deg
    }
    for i in range(num_cells):
        min10 = parts[2 * i]
        max10 = parts[2 * i + 1]
        # Precision = index of FIRST position where min10 and max10
        # disagree (they must match on the cell prefix and disagree
        # on the padding).
        prec = 10
        for k in range(10):
            if min10[k] != max10[k]:
                prec = k
                break
        if prec < 1: prec = 1
        if prec > 7: prec = 7
        total_area += GH_CELL_AREA.get(prec, 0)
    return num_cells, total_area


def qz_count_and_area(side, max_cells):
    """qz adaptive cover via the text-pair output. The level for each
    cell is recovered the same way we do for gh: find the position
    where min30 and max30 first disagree -- that's the cell-prefix
    length, which equals the level (each base-4 char = 1 level)."""
    mn_lon, mn_lat, mx_lon, mx_lat = rect_bbox_deg(LAT, LON, side)
    sql = (f"SELECT c_qz_cover_geometry_str(ST_MakeEnvelope("
           f"{mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, 4326), "
           f"{QZ_MIN_LEVEL}, {QZ_MAX_LEVEL}, {max_cells});")
    out = run_one(sql)
    if not out.startswith("{") or not out.endswith("}"):
        return 0, 0.0
    body = out[1:-1].strip()
    if not body:
        return 0, 0.0
    parts = body.split(",")
    if len(parts) % 2 != 0:
        return 0, 0.0
    num_cells = len(parts) // 2
    total_area = 0.0
    QZ_STR_WIDTH = 30
    for i in range(num_cells):
        min30 = parts[2 * i]
        max30 = parts[2 * i + 1]
        # Level = first index where min30 and max30 disagree (they
        # match on the cell prefix and diverge starting at the
        # padding).
        level = QZ_STR_WIDTH
        for k in range(QZ_STR_WIDTH):
            if min30[k] != max30[k]:
                level = k
                break
        if level < 0: level = 0
        if level > QZ_MAX_LEVEL: level = QZ_MAX_LEVEL
        total_area += qz_cell_area_km2(level)
    return num_cells, total_area


def s2_count_and_area(side, max_cells):
    """For S2, we don't have a direct level helper exposed in SQL, so we
    use the cell IDs and compute level from the trailing-1 marker
    (s2_cell_range_min/max are exposed). Simpler: just use cell count
    and assume average S2 cell area at the level S2 picks. Actually we
    can call s2_cell_range_min and infer level from the lsb. Even
    simpler: just report cells without area for S2, since we're mainly
    interested in the cells column. Add area if needed."""
    mn_lon, mn_lat, mx_lon, mx_lat = rect_bbox_deg(LAT, LON, side)
    sql = (f"SELECT cell FROM unnest(ST_S2Covering(ST_MakeEnvelope("
           f"{mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, 4326), "
           f"{S2_MIN_LEVEL}, {S2_MAX_LEVEL}, {max_cells})) cell;")
    out = run_one(sql)
    if not out:
        return 0, 0.0
    cells = []
    for line in out.split("\n"):
        if not line.strip():
            continue
        try:
            cells.append(int(line))
        except ValueError:
            pass
    num_cells = len(cells)
    # S2 cell ID layout: 60 position bits + 1 marker. Level computed
    # from the position of the trailing-1 bit. Quick implementation in
    # Python: for cell C (signed int64), find the lowest set bit.
    total_area = 0.0
    for c in cells:
        if c == 0:
            continue
        # Find the lsb (Python: c & -c works on signed too if c > 0)
        # S2 cells are typically positive but let's handle uint64.
        c_u = c & ((1 << 63) - 1) if c < 0 else c
        # Actually S2 cell IDs can use the high bit. Use proper unsigned.
        # Simpler: convert to uint64.
        c_u = c & 0xFFFFFFFFFFFFFFFF if c >= 0 else (c + (1 << 64)) & 0xFFFFFFFFFFFFFFFF
        if c_u == 0:
            continue
        lsb = c_u & (-c_u & 0xFFFFFFFFFFFFFFFF)
        # S2 level: max_level (30) - log2(lsb) / 2
        log_lsb = lsb.bit_length() - 1
        level = (60 - log_lsb) // 2
        # Hmm wait, S2 has a 3-bit face prefix at the top. Level = 30 - (log_lsb / 2)?
        # S2 cell ID format: 1 sign(0) + 3 face + 60 position + 1 marker = 65 bits...
        # Actually it's 64 bits: 3 face + 60 position + 1 marker = 64 bits.
        # Level = 30 - log_lsb/2 if marker is at position 0..60.
        # Let's just use s2_cell_range_min and infer level from the BLOCK SIZE.
        # block_size = (range_max - range_min) / 2 + 1 = lsb. level = 30 - log_lsb/2.
        level = (60 - log_lsb) // 2
        if level < 0:
            level = 0
        if level > 30:
            level = 30
        total_area += s2_cell_area_km2(level)
    return num_cells, total_area


def main():
    print("# Three-way adaptive coverer sweep (lat=0, lon=7)")
    print(f"# All three systems: same priority-queue algorithm + max_cells budget")
    print(f"# gh = (32-ary, Z), qz = (4-ary, Z), S2 = (4-ary, Hilbert)\n")

    here = os.path.dirname(os.path.realpath(__file__))
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir = os.path.join(here, "results", f"run_{ts}")
    os.makedirs(run_dir, exist_ok=True)
    csv_path = os.path.join(run_dir, "three_way_adaptive.csv")
    csv_fp = open(csv_path, "w", newline="")
    csv_w = csv.writer(csv_fp)
    cols = ["side_km", "max_cells", "query_area_km2"]
    for sys_name in ["gh", "qz", "s2"]:
        cols += [f"{sys_name}_cells", f"{sys_name}_cover_area_km2",
                 f"{sys_name}_overfetch"]
    csv_w.writerow(cols)
    print(f"# CSV -> {csv_path}\n")

    header = (f"| {'side':>5} | {'budget':>6} | "
              f"{'gh':>5} | {'gh_over':>7} | "
              f"{'qz':>5} | {'qz_over':>7} | "
              f"{'s2':>5} | {'s2_over':>7} |")
    sep = "|" + "|".join(["-"*7]*8) + "|"
    print(header); print(sep)

    for max_cells in BUDGETS:
        for side in SIDE_KM:
            qa = query_area_km2(side)

            gh_n, gh_area = gh_count_and_area(side, max_cells)
            qz_n, qz_area = qz_count_and_area(side, max_cells)
            s2_n, s2_area = s2_count_and_area(side, max_cells)

            gh_over = (gh_area / qa) if qa > 0 else 0
            qz_over = (qz_area / qa) if qa > 0 else 0
            s2_over = (s2_area / qa) if qa > 0 else 0

            print(f"| {side:>3}km | {max_cells:>6} | "
                  f"{gh_n:>5} | {gh_over:>5.1f}x | "
                  f"{qz_n:>5} | {qz_over:>5.1f}x | "
                  f"{s2_n:>5} | {s2_over:>5.1f}x |", flush=True)

            csv_w.writerow([side, max_cells, qa,
                            gh_n, gh_area, gh_over,
                            qz_n, qz_area, qz_over,
                            s2_n, s2_area, s2_over])
            csv_fp.flush()
        print(sep)

    csv_fp.close()
    print(f"\n# CSV written to {csv_path}")


if __name__ == "__main__":
    main()
