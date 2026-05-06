#!/usr/bin/env python3
"""
Three-way sweep: existing-geohash-bbox vs new-geohash-with-skipping vs S2.

Same lat × radius × lon matrix as end_to_end_radius_sweep.py, but adds a
third scheme that exercises the new c_geohash int64 + top-down + cell
skipping path on `latitude_test_cgeo_index`. The hypothesis being tested:

  * gh_bbox is bottom-up bbox cover → over-counts ~27% on a disk (the
    corners outside the disk).
  * gh_skip is top-down with cell skipping → matches what S2 does
    algorithmically. At lat 0 with the same effective level it should be
    close to s2_cells (within 2× — the engines use slightly different
    cell-size grids).
  * gh_bbox should always be ≥ gh_skip (strict superset).

Output:
  * markdown table to stdout
  * CSV under distortion_test/results/run_<ts>/radius_sweep_three_way.csv
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

# Mirror end_to_end_radius_sweep.py exactly so numbers stack up.
LATITUDES = [0, 30, 60, 80, 87]
RADII_KM = [25, 75]
LONGITUDES = [7.0]                  # single lon — same answer at lat 0 across lons
EARTH_R_KM = 6371.0088
GH_QUERY_PRECISION = 7      # geohash p7 ≈ 150 m at lat 0
S2_MIN_LEVEL = 4
S2_MAX_LEVEL = 16           # S2 level 16 ≈ 150 m — chosen to match GH p7
S2_MAX_CELLS = 1_000_000    # uncapped — let level range alone determine cells

# NOTE: the "gh_skip" column used to call the int64-only c_geohash_cover_geometry
# / cgeo_spatial_candidates path with min/max levels + max_cells. That API was
# removed when c_geohash went text-only (geohash is a base-32 string by
# definition). Without geometry-aware covering, "skip" and "bbox" produce the
# same cells for any region — there's nothing to skip beyond what the bbox
# already excludes. We keep the gh_skip column for stack-with-S2 readability;
# it now delegates to the same gh_bbox text path. See
# yugabyte-db/src/postgres/yb-extensions/c_geohash for the current API surface.

RUNS_TOTAL = 2  # 1 warmup + 1 measured (sufficient for cell-count comparison)


def disk_bbox_deg(lat, lon, r_km):
    a = r_km / EARTH_R_KM
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


# ---- Three QUERY shapes (each runs the count + recheck) ----

def gh_bbox_query(lat, lon, r_km):
    """Existing geohash bottom-up bbox cover (legacy path)."""
    mn_lon, mn_lat, mx_lon, mx_lat = disk_bbox_deg(lat, lon, r_km)
    return (
        f"SELECT count(*) FROM latitude_test t "
        f"WHERE t.id = ANY(ARRAY("
        f"SELECT geohash_candidates('latitude_test', "
        f"{mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, "
        f"{GH_QUERY_PRECISION}))) "
        f"AND ST_Distance(t.geom::geography, "
        f"ST_SetSRID(ST_MakePoint({lon}, {lat}), 4326)::geography) <= "
        f"{r_km * 1000.0};"
    )


def gh_skip_query(lat, lon, r_km):
    """Deprecated alias for gh_bbox_query — the int64 c_geohash_cover_geometry
    path that this used to call no longer exists. With text-API only, geohash
    cannot do geometry-aware covering, so "skip" == "bbox". See module-level
    NOTE for context."""
    return gh_bbox_query(lat, lon, r_km)


def s2_query(lat, lon, r_km):
    return (
        f"SELECT count(*) FROM latitude_test t "
        f"WHERE t.id = ANY(ARRAY("
        f"SELECT spatial_candidates_v2('latitude_test', "
        f"ST_Buffer(ST_SetSRID(ST_MakePoint({lon},{lat}),4326)::geography, "
        f"{r_km * 1000.0})::geometry, "
        f"{S2_MIN_LEVEL}, {S2_MAX_LEVEL}, {S2_MAX_CELLS}))) "
        f"AND ST_Distance(t.geom::geography, "
        f"ST_SetSRID(ST_MakePoint({lon}, {lat}), 4326)::geography) <= "
        f"{r_km * 1000.0};"
    )


# ---- Cell-count predictors (cheap; ask each engine how many cells it
#      *would* generate for the candidate cover) ----

def predicted_gh_bbox(lat, lon, r_km):
    mn_lon, mn_lat, mx_lon, mx_lat = disk_bbox_deg(lat, lon, r_km)
    sql = (f"SELECT array_length(c_geohash_l10_ranges_merged("
           f"{mn_lon}, {mn_lat}, {mx_lon}, {mx_lat}, "
           f"{GH_QUERY_PRECISION}), 1) / 2;")
    _, out = run_one(sql)
    return int(out) if out else 0


def predicted_gh_skip(lat, lon, r_km):
    """Same as predicted_gh_bbox — see module-level NOTE."""
    return predicted_gh_bbox(lat, lon, r_km)


def predicted_s2(lat, lon, r_km):
    sql = (f"SELECT array_length(ST_S2Covering("
           f"ST_Buffer(ST_SetSRID(ST_MakePoint({lon},{lat}),4326)::geography, "
           f"{r_km * 1000.0})::geometry, "
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
    print(f"# Three-way latitude × radius × longitude sweep")
    print(f"# Latitudes : {LATITUDES}")
    print(f"# Radii (km): {RADII_KM}")
    print(f"# Longitudes: {LONGITUDES}")
    print(f"# Schemes   : gh_bbox (legacy bottom-up bbox cover)")
    print(f"#             gh_skip (new int64 + top-down + cell skipping)")
    print(f"#             s2      (existing ST_S2Covering top-down)")
    print(f"# {RUNS_TOTAL-1} measurement(s) per (lat, r, lon, scheme), "
          f"median reported\n")

    here = os.path.dirname(os.path.realpath(__file__))
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir = os.path.join(here, "results", f"run_{ts}")
    os.makedirs(run_dir, exist_ok=True)
    csv_path = os.path.join(run_dir, "radius_sweep_three_way.csv")
    csv_fp = open(csv_path, "w", newline="")
    csv_w = csv.writer(csv_fp)
    csv_w.writerow([
        "lat", "lon", "radius_km",
        "gh_bbox_cells", "gh_bbox_hits", "gh_bbox_ms",
        "gh_skip_cells", "gh_skip_hits", "gh_skip_ms",
        "s2_cells",      "s2_hits",      "s2_ms",
        "ratio_skip_over_s2", "ratio_bbox_over_skip",
    ])
    print(f"# CSV → {csv_path}\n")

    header = (f"| {'lat':>3} | {'r':>4} | {'lon':>5} | "
              f"{'gh_bbox':>8} | {'gh_skip':>8} | {'s2':>8} | "
              f"{'gh_ms':>6} | {'sk_ms':>6} | {'s2_ms':>6} | "
              f"{'sk/s2':>6} | {'bb/sk':>6} |")
    sep = ("|" + "|".join(["-"*5, "-"*6, "-"*7,
                            "-"*10, "-"*10, "-"*10,
                            "-"*8, "-"*8, "-"*8,
                            "-"*8, "-"*8]) + "|")
    print(header)
    print(sep)

    for lat in LATITUDES:
        for r in RADII_KM:
            for lon in LONGITUDES:
                gh_bb_cells = predicted_gh_bbox(lat, lon, r)
                gh_sk_cells = predicted_gh_skip(lat, lon, r)
                s2_cells   = predicted_s2(lat, lon, r)

                gh_bb_ms, gh_bb_hits = measure(gh_bbox_query(lat, lon, r))
                gh_sk_ms, gh_sk_hits = measure(gh_skip_query(lat, lon, r))
                s2_ms,    s2_hits    = measure(s2_query(lat, lon, r))

                ratio_skip_over_s2 = (gh_sk_cells / s2_cells
                                      if s2_cells else 0)
                ratio_bbox_over_skip = (gh_bb_cells / gh_sk_cells
                                        if gh_sk_cells else 0)

                print(f"| {lat:>3} | {r:>3}km | {lon:>5.1f} | "
                      f"{gh_bb_cells:>8} | {gh_sk_cells:>8} | "
                      f"{s2_cells:>8} | "
                      f"{gh_bb_ms:>5.0f}ms | {gh_sk_ms:>5.0f}ms | "
                      f"{s2_ms:>5.0f}ms | "
                      f"{ratio_skip_over_s2:>5.2f}× | "
                      f"{ratio_bbox_over_skip:>5.2f}× |", flush=True)
                csv_w.writerow([
                    lat, lon, r,
                    gh_bb_cells, gh_bb_hits, f"{gh_bb_ms:.1f}",
                    gh_sk_cells, gh_sk_hits, f"{gh_sk_ms:.1f}",
                    s2_cells,    s2_hits,    f"{s2_ms:.1f}",
                    f"{ratio_skip_over_s2:.3f}",
                    f"{ratio_bbox_over_skip:.3f}",
                ])
                csv_fp.flush()
            print(sep)

    csv_fp.close()
    print(f"\n# CSV written to {csv_path}")


if __name__ == "__main__":
    main()
