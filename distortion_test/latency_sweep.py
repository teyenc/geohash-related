#!/usr/bin/env python3
"""
Latency + RPC sweep across (system, latitude, longitude). Four databases,
each engine in its native DB so the two extensions never coexist:

  bench_dans : Dan's pure-SQL geohash helpers + my_mapdata (geo_hash10
               column) + LEFT(geo_hash10, 6) expression index.
                 pure_sql  -- LEFT(geo_hash10, 6) = ANY(geohash_cells_for_bbox(...))

  bench_cgeo : c_geohash standalone (its own geometry type + ST_* surface) +
               my_mapdata_cgeo_index mapping table.
                 c_geohash -- (32-ary tree, Z-order curve)
                 md_pk IN (SELECT cgeo_text_spatial_candidates(...))

  bench_qz   : c_quadtree_z + c_geohash (for geometry type) +
               my_mapdata_qz_index mapping table + qz_text_spatial_candidates
               (installed by 05_setup_yb_qz.sh).
                 qz        -- (4-ary tree, Z-order curve)
                 md_pk IN (SELECT qz_text_spatial_candidates(...))

  bench_s2   : yb_geospatial_s2 + my_mapdata_s2_index + spatial_candidates_v2
               (parameterized cover, installed by 02_setup_yb_s2.sh).
                 s2        -- (4-ary tree, Hilbert curve)
                 md_pk IN (SELECT spatial_candidates_v2(...))

The four-way comparison isolates two independent variables:
  gh vs qz  : branching factor (32-ary vs 4-ary), same Z-order curve
  qz vs s2  : space-filling curve (Z-order vs Hilbert), same 4-ary tree
This is exactly the experiment the Moon-Jagadish-Faloutsos-Saltz paper
predicts a ~43-48% cluster-count reduction for (qz_clusters / s2_clusters
should land near 1.85 for matched-leaf-size queries).

All three DBs are seeded from the same 19_mapData.pipe file via \\copy, so
row contents are identical; only the index structure differs.

Recheck in every engine is via ST_X(geom) / ST_Y(geom) lat/lon BETWEEN
bbox — no ST_Intersects, so the yb_geospatial_s2 planner hook never fires
in any DB.

Per (sys, lat, lon): WARMUP_RUNS discarded + MEASURED_RUNS recorded. Each
system runs in its own ysqlsh session (one per DB).
"""
import argparse
import csv
import os
import re
import statistics
import subprocess
import sys
import time

from sweep_config import LATENCY_LATITUDES as LATITUDES, LONGITUDES
from sweep_queries import QUERY_BUILDERS

YSQL = "/net/dev-server-te-yenchou/share/code/yugabyte-db/build/latest/postgres/bin/ysqlsh"
HOST = "127.0.0.1"
PORT = "5433"
USER = "yugabyte"
OUT_DIR = "/net/dev-server-te-yenchou/share/code/geohash-related/distortion_test/results"
os.makedirs(OUT_DIR, exist_ok=True)

# LATITUDES, LONGITUDES, SIDE_KM are imported from sweep_config.py so this
# sweep and cell_count_sweep.py share the same x-axis sampling.
# QUERY_BUILDERS (and the per-engine cover-level params + envelope helpers)
# live in sweep_queries.py — edit there if you need to change the SQL.
WARMUP_RUNS    = 1
MEASURED_RUNS  = 2

SYSTEM_DB = {
    'pure_sql':  'bench_dans',
    'c_geohash': 'bench_cgeo',
    'qz':        'bench_qz',
    's2':        'bench_s2',
}
SYSTEMS = ['pure_sql', 'c_geohash', 'qz', 's2']


# ---------------------------------------------------------------------------
# ysqlsh helpers
# ---------------------------------------------------------------------------
def run_sql_in(db, sql):
    args = [YSQL, "-h", HOST, "-p", PORT, "-U", USER, "-X", "-d", db]
    p = subprocess.run(args, input=sql, capture_output=True, text=True)
    return p.stdout, p.stderr


def preflight():
    """Verify each engine's native DB has what its query needs."""
    checks = {
        'bench_dans': """
            SELECT
              (SELECT count(*) FROM pg_proc WHERE proname='geohash_cells_for_bbox') AS dans_cells,
              (SELECT count(*) FROM pg_class WHERE relname='my_mapdata_left_gh6_idx') AS gh6_idx,
              (SELECT count(*) FROM my_mapdata) AS rows;
        """,
        'bench_cgeo': """
            SELECT
              (SELECT count(*) FROM pg_extension WHERE extname='c_geohash') AS cgh,
              (SELECT count(*) FROM pg_proc WHERE proname='cgeo_text_spatial_candidates') AS cgeo_cands,
              (SELECT count(*) FROM my_mapdata) AS rows,
              (SELECT count(*) FROM my_mapdata_cgeo_index) AS cgeo_idx;
        """,
        'bench_qz': """
            SELECT
              (SELECT count(*) FROM pg_extension WHERE extname='c_quadtree_z') AS qz_ext,
              (SELECT count(*) FROM pg_proc WHERE proname='qz_text_spatial_candidates') AS qz_cands,
              (SELECT count(*) FROM my_mapdata) AS rows,
              (SELECT count(*) FROM my_mapdata_qz_index) AS qz_idx;
        """,
        'bench_s2': """
            SELECT
              (SELECT count(*) FROM pg_extension WHERE extname='yb_geospatial_s2') AS s2_ext,
              (SELECT count(*) FROM pg_proc WHERE proname='spatial_candidates_v2') AS s2_cands,
              (SELECT count(*) FROM my_mapdata) AS rows,
              (SELECT count(*) FROM my_mapdata_s2_index) AS s2_idx;
        """,
    }
    # Only preflight DBs that one of the currently-selected engines uses
    # (after any CLI filtering of SYSTEMS). Probing an unused DB is harmless
    # but noisy, and confusing if it's missing.
    dbs_in_use = {SYSTEM_DB[s] for s in SYSTEMS}
    for db in sorted(dbs_in_use):
        print(f"[preflight] {db}:")
        out, _ = run_sql_in(db, checks[db])
        for line in out.strip().splitlines():
            print("  " + line)
    print()


# ---------------------------------------------------------------------------
# Build per-DB scripts (all queries for systems mapped to that DB)
# ---------------------------------------------------------------------------
def build_script_for_db(db):
    sys_in_db = [s for s in SYSTEMS if SYSTEM_DB[s] == db]
    lines = [
        "\\pset format unaligned\n",
        "\\pset footer off\n",
        "\\pset tuples_only off\n",
    ]
    for sys_name in sys_in_db:
        builder = QUERY_BUILDERS[sys_name]
        for lat in LATITUDES:
            for lon in LONGITUDES:
                for run_idx in range(-WARMUP_RUNS, MEASURED_RUNS):
                    is_warm = run_idx < 0
                    tag = (f"sys={sys_name}|lat={lat}|lon={lon}"
                           f"|run={run_idx}|warmup={is_warm}")
                    lines.append(f"\\echo @@@MARK_BEGIN@@@ {tag}\n")
                    lines.append(builder(lat, lon))
                    lines.append(f"\\echo @@@MARK_END@@@ {tag}\n")
    return "".join(lines)


EXEC_RE  = re.compile(r"Execution Time:\s*([\d.]+)\s*ms")
READS_RE = re.compile(r"^\s*Storage Read Requests:\s*(\d+)", re.MULTILINE)


def parse_count_from_block(body):
    lines = [l.strip() for l in body.splitlines() if l.strip()]
    for l in reversed(lines):
        if l.isdigit():
            return int(l)
    return -1


def parse_output(text):
    blocks = re.split(r"@@@MARK_BEGIN@@@ ", text)
    for blk in blocks[1:]:
        head, _, body = blk.partition("\n")
        body, _, _   = body.partition("@@@MARK_END@@@")
        kv = dict(p.split("=", 1) for p in head.strip().split("|"))
        m_time  = EXEC_RE.search(body)
        m_reads = READS_RE.search(body)
        cnt     = parse_count_from_block(body)
        yield {
            'sys':           kv['sys'],
            'lat':           int(kv['lat']),
            'lon':           float(kv['lon']),
            'run':           int(kv['run']),
            'warmup':        kv['warmup'] == 'True',
            'exec_ms':       float(m_time.group(1))   if m_time  else None,
            'storage_reads': int(m_reads.group(1))    if m_reads else None,
            'count':         cnt,
        }


def main():
    global SYSTEMS
    parser = argparse.ArgumentParser(
        description=("Distortion latency sweep across latitudes. Default "
                     "engines: c_geohash, s2 (the main 2-way comparison). "
                     "Use --with-pure-sql for Dan's pure-SQL baseline, "
                     "--with-qz for the Hilbert-vs-Z-order isolation."))
    parser.add_argument(
        '--with-pure-sql', action='store_true',
        help=("Include the pure_sql (Dan's plpgsql) engine. Off by default "
              "because the pure_sql baseline isn't part of the current "
              "distortion comparison and re-measuring it just adds bench_dans "
              "traffic. Pass this flag if you specifically want the pure_sql "
              "numbers for a particular report."))
    parser.add_argument(
        '--with-qz', action='store_true',
        help=("Include the qz (c_quadtree_z) engine. Off by default — the "
              "main comparison is c_geohash vs s2; qz is the auxiliary "
              "Hilbert-vs-Z-order isolation experiment (4-ary tree + Z curve, "
              "matches s2's branching factor but uses gh's curve)."))
    args = parser.parse_args()

    # Both pure_sql and qz are excluded by default — only include if asked.
    skips = []
    if not args.with_pure_sql: skips.append('pure_sql')
    if not args.with_qz:       skips.append('qz')
    SYSTEMS = [s for s in SYSTEMS if s not in skips]
    print(f"[config] running engines = {SYSTEMS}"
          + (f"   (skipped: {skips})" if skips else ""))

    preflight()

    dbs_in_use = {SYSTEM_DB[s] for s in SYSTEMS}
    n_per_db = {db: 0 for db in dbs_in_use}
    for s in SYSTEMS:
        n_per_db[SYSTEM_DB[s]] += (len(LATITUDES) * len(LONGITUDES) *
                                    (WARMUP_RUNS + MEASURED_RUNS))
    total = sum(n_per_db.values())
    print(f"[benchmark] {total} queries total: {n_per_db}")

    ts = time.strftime("%Y%m%d_%H%M%S")
    # Bundle every artifact (raw, csv, future plot, summary) for this run
    # into one per-run subfolder so the top-level results/ dir stays scannable.
    run_dir  = os.path.join(OUT_DIR, f"run_{ts}")
    os.makedirs(run_dir, exist_ok=True)
    raw_path = os.path.join(run_dir, f"latency_sweep_{ts}.raw.txt")
    csv_path = os.path.join(run_dir, f"latency_sweep_{ts}.csv")

    all_rows = []
    raw_acc = ""
    for db in sorted(dbs_in_use):
        script = build_script_for_db(db)
        sys_in_db = [s for s in SYSTEMS if SYSTEM_DB[s] == db]
        print(f"[{db}] running {len(sys_in_db)} system(s) "
              f"({n_per_db[db]} queries, {len(script)} bytes)...")
        t0 = time.time()
        out, err = run_sql_in(db, script)
        print(f"  done in {time.time() - t0:.1f}s")
        if err.strip():
            print(f"  stderr (first 1500): {err[:1500]}", file=sys.stderr)
        raw_acc += f"\n@@@DB={db}@@@\n" + out
        all_rows.extend(parse_output(out))

    with open(raw_path, "w") as f:
        f.write(raw_acc)
    print(f"  raw -> {raw_path}")
    with open(csv_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=['sys','lat','lon','run','warmup',
                                          'exec_ms','storage_reads','count'])
        w.writeheader()
        for r in all_rows:
            w.writerow(r)
    print(f"  parsed {len(all_rows)}/{total} blocks -> {csv_path}")

    # ---------- summary ----------
    print()
    print("=== summary (median across measured runs, all longitudes pooled) ===")
    print(f"{'sys':<11}{'lat':<5}{'med_exec_ms':>13}{'med_reads':>11}"
          f"{'med_count':>11}{'n':>5}")
    by_key = {}
    for r in all_rows:
        if r['warmup'] or r['exec_ms'] is None:
            continue
        k = (r['sys'], r['lat'])
        by_key.setdefault(k, {'exec_ms': [], 'reads': [], 'count': []})
        by_key[k]['exec_ms'].append(r['exec_ms'])
        if r['storage_reads'] is not None:
            by_key[k]['reads'].append(r['storage_reads'])
        if r['count'] >= 0:
            by_key[k]['count'].append(r['count'])

    for sys_name in SYSTEMS:
        for lat in LATITUDES:
            d = by_key.get((sys_name, lat))
            if d is None or not d['exec_ms']:
                print(f"{sys_name:<11}{lat:<5}{'(no data)':>13}")
                continue
            em = statistics.median(d['exec_ms'])
            sr = statistics.median(d['reads']) if d['reads'] else 0
            ct = statistics.median(d['count']) if d['count'] else 0
            print(f"{sys_name:<11}{lat:<5}{em:>13.1f}{sr:>11.0f}"
                  f"{ct:>11.0f}{len(d['exec_ms']):>5}")

    # Auto-plot: pipe the freshly-written CSV into plot_latency.py so the
    # 3-panel chart (ms / RPCs / ratio-vs-s2) lands in the same run folder.
    # Failure is non-fatal — the CSV is already on disk.
    here = os.path.dirname(os.path.realpath(__file__))
    plot_script = os.path.join(here, "plot_latency.py")
    print(f"\n[auto-plot] running plot_latency.py ...")
    rc = subprocess.run([sys.executable, plot_script, csv_path]).returncode
    if rc != 0:
        print(f"  (plot failed with exit {rc}; CSV is still at {csv_path})",
              file=sys.stderr)


if __name__ == "__main__":
    main()
