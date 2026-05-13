#!/usr/bin/env python3
"""
Plot latency_sweep CSV: two side-by-side panels.
  panel A: median Execution Time (ms) vs latitude
  panel B: median Storage Read Requests vs latitude
3 lines per panel: pure_sql / c_geohash / s2.
Linear axes, no shadow band, simple lines.
"""
import csv
import os
import statistics
import sys

import matplotlib.pyplot as plt

DEFAULT_CSV = None
RESULTS_DIR = ("/net/dev-server-te-yenchou/share/code/geohash-related/"
               "distortion_test/results")


def load(csv_path):
    rows = []
    with open(csv_path) as f:
        for r in csv.DictReader(f):
            r['lat']           = int(r['lat'])
            r['lon']           = float(r['lon'])
            r['warmup']        = r['warmup'] == 'True'
            r['exec_ms']       = float(r['exec_ms'])       if r['exec_ms']       else None
            r['storage_reads'] = int(r['storage_reads'])   if r['storage_reads'] else None
            r['count']         = int(r['count'])           if r['count']         else -1
            rows.append(r)
    return rows


def aggregate(rows, metric):
    """Returns {sys: {lat: median_metric}} pooling across longitudes/runs."""
    by = {}
    for r in rows:
        if r['warmup'] or r[metric] is None:
            continue
        by.setdefault(r['sys'], {}).setdefault(r['lat'], []).append(r[metric])
    return {sys_: {lat: statistics.median(v) for lat, v in lats.items()}
            for sys_, lats in by.items()}


def main():
    csv_path = sys.argv[1] if len(sys.argv) > 1 else None
    if csv_path is None:
        candidates = sorted(
            f for f in os.listdir(RESULTS_DIR)
            if f.startswith("latency_sweep_") and f.endswith(".csv"))
        if not candidates:
            print(f"no latency_sweep_*.csv in {RESULTS_DIR}", file=sys.stderr)
            sys.exit(1)
        csv_path = os.path.join(RESULTS_DIR, candidates[-1])
    print(f"loading {csv_path}")

    rows = load(csv_path)
    by_exec  = aggregate(rows, 'exec_ms')
    by_reads = aggregate(rows, 'storage_reads')

    fig, (axA, axB) = plt.subplots(1, 2, figsize=(12, 4.5))

    # Stable color/marker per system.
    palette = {
        'c_geohash': ('#d62728', 's'),
        's2':        ('#2ca02c', '^'),
    }
    # pure_sql is the demo baseline measured by the perf-bootstrap benchmark,
    # not by this distortion sweep -- it has a fundamentally different shape
    # (1 RPC always, regardless of cell count) so dropping it lets the chart
    # show the c_geohash-vs-S2 distortion comparison cleanly.
    sys_order = ['c_geohash', 's2']

    for ax, data, title, ylabel in [
        (axA, by_exec,  'Execution Time vs Latitude',     'median ms'),
        (axB, by_reads, 'Storage Read Requests vs Latitude', 'median RPCs'),
    ]:
        for sys_ in sys_order:
            if sys_ not in data:
                continue
            lats = sorted(data[sys_].keys())
            ys   = [data[sys_][l] for l in lats]
            color, marker = palette[sys_]
            ax.plot(lats, ys, color=color, marker=marker, linewidth=2,
                    markersize=7, label=sys_)
        ax.set_xlabel('latitude (degrees)')
        ax.set_ylabel(ylabel)
        ax.set_title(title)
        ax.grid(True, linestyle=':', alpha=0.5)
        ax.legend()

    fig.suptitle(f"latency sweep — {os.path.basename(csv_path)}",
                 fontsize=10)
    fig.tight_layout()
    out_png = csv_path.replace('.csv', '.png')
    fig.savefig(out_png, dpi=110, bbox_inches='tight')
    print(f"wrote {out_png}")


if __name__ == "__main__":
    main()
