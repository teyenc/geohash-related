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
        # Look both at the top level (legacy flattened runs) and inside any
        # run_*/ subfolder (current layout, written by latency_sweep.py).
        # Sort by basename so the latest timestamp wins regardless of where
        # the CSV lives.
        candidates = []
        for f in os.listdir(RESULTS_DIR):
            full = os.path.join(RESULTS_DIR, f)
            if (os.path.isfile(full) and f.startswith("latency_sweep_")
                    and f.endswith(".csv")):
                candidates.append(full)
            elif os.path.isdir(full) and f.startswith("run_"):
                for sub in os.listdir(full):
                    if sub.startswith("latency_sweep_") and sub.endswith(".csv"):
                        candidates.append(os.path.join(full, sub))
        if not candidates:
            print(f"no latency_sweep_*.csv in {RESULTS_DIR} (or its run_*/ subdirs)",
                  file=sys.stderr)
            sys.exit(1)
        candidates.sort(key=os.path.basename)  # sort by CSV filename = ts
        csv_path = candidates[-1]
    print(f"loading {csv_path}")

    rows = load(csv_path)
    by_exec  = aggregate(rows, 'exec_ms')
    by_reads = aggregate(rows, 'storage_reads')

    # 2x2 grid:
    #   top row    = absolute values (ms | RPCs)
    #   bottom row = ratio vs s2     (ms / s2_ms | RPCs / s2_RPCs)
    # Bottom mirrors top so each "cost axis" has its absolute + ratio view.
    fig, ((axA, axB), (axC, axD)) = plt.subplots(2, 2, figsize=(13, 9))

    # Stable color/marker per system.
    palette = {
        'c_geohash': ('#d62728', 's'),    # 32-ary, Z-order
        'qz':        ('#f46d43', 'D'),    # 4-ary, Z-order  (isolates branching)
        's2':        ('#2ca02c', '^'),    # 4-ary, Hilbert  (isolates curve)
    }
    # pure_sql is the demo baseline measured by the perf-bootstrap benchmark,
    # not by this distortion sweep -- it has a fundamentally different shape
    # (1 RPC always, regardless of cell count) so dropping it lets the chart
    # show the gh-vs-qz-vs-S2 distortion comparison cleanly.
    sys_order = ['c_geohash', 'qz', 's2']

    # ---------- top row: absolute values ----------
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

    # ---------- bottom row: ratio vs s2 ----------
    def plot_ratio_panel(ax, data, metric_label):
        """Plot engine/s2 ratio for each non-s2 engine; annotate each point
        with its 'Nx' multiplier."""
        ax.axhline(1.0, color='grey', linewidth=0.8, linestyle='--',
                   label='parity (1×)')
        if 's2' not in data:
            ax.set_title(f"{metric_label} ratio vs S2  (no s2 baseline this run)")
            return
        s2_at = data['s2']
        for sys_ in sys_order:
            if sys_ == 's2' or sys_ not in data:
                continue
            lats   = sorted(l for l in data[sys_].keys() if l in s2_at)
            ratios = [data[sys_][l] / s2_at[l] for l in lats]
            color, marker = palette[sys_]
            ax.plot(lats, ratios, color=color, marker=marker, linewidth=2,
                    markersize=7, label=f"{sys_} / s2")
            for x, y in zip(lats, ratios):
                ax.annotate(f"{y:.1f}×", xy=(x, y), xytext=(4, 4),
                            textcoords='offset points',
                            fontsize=8, color=color)
        ax.set_xlabel('latitude (degrees)')
        ax.set_ylabel(f'{metric_label} / s2 {metric_label}')
        ax.set_title(f'{metric_label} ratio vs S2  (>1 = engine more costly than s2)')
        ax.grid(True, linestyle=':', alpha=0.5)
        ax.legend()

    plot_ratio_panel(axC, by_exec,  'exec_ms')
    plot_ratio_panel(axD, by_reads, 'RPCs')

    fig.suptitle(f"latency sweep — {os.path.basename(csv_path)}",
                 fontsize=10)
    fig.tight_layout()
    out_png = csv_path.replace('.csv', '.png')
    fig.savefig(out_png, dpi=110, bbox_inches='tight')
    print(f"wrote {out_png}")


if __name__ == "__main__":
    main()
