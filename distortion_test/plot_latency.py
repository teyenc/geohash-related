#!/usr/bin/env python3
"""
Plot latency_sweep CSV: four separate PNGs (one chart per file) so each
is a standalone artifact you can drop into a slide / doc without cropping.

  exec_ms.png        query execution time (ms) vs latitude, with per-point
                     ratio-to-s2 annotations on the gh and qz lines
  rpcs.png           DocDB storage round-trips vs latitude (RPCs), same
                     ratio annotation idiom
  exec_ms_ratio.png  ratio-only zoom-in of the execution-time chart
                     (gh/s2 and qz/s2 lines with Nx labels)
  rpcs_ratio.png     ratio-only zoom-in of the round-trips chart

Each chart reads the run's metadata.json (next to the CSV) and bakes the
run parameters (table, shape, envelope size, longitude, engine cover
levels) into a subtitle — same approach as cells_vs_lat.png in the
cell_count_sweep plot. That way a chart pulled out of context still
tells you which experiment produced it.
"""
import csv
import json
import os
import statistics
import sys

import matplotlib.pyplot as plt

DEFAULT_CSV = None
RESULTS_DIR = ("/net/dev-server-te-yenchou/share/code/geohash-related/"
               "distortion_test/results")

# Stable color/marker per engine — used by every panel so a reader can
# pick out "the orange D is qz" across all four charts.
PALETTE = {
    'c_geohash': ('#d62728', 's'),    # 32-ary, Z-order
    'qz':        ('#f46d43', 'D'),    # 4-ary,  Z-order  (isolates branching)
    's2':        ('#2ca02c', '^'),    # 4-ary,  Hilbert  (isolates curve)
    'pure_sql':  ('#7f7f7f', 'x'),    # Dan's plpgsql
}
SYS_ORDER = ['pure_sql', 'c_geohash', 'qz', 's2']

# Detailed legend labels — keep in sync with sweep_queries.py constants.
ENGINE_LABEL = {
    'pure_sql':  "pure_sql — Dan's plpgsql (LEFT(gh10, 6) bucket lookup)",
    'c_geohash': "c_geohash — 32-ary, Z-order (gh-7 leaf, ~152 m cells)",
    'qz':        "quadtree-Z — 4-ary, Z-order (qz-18 leaf, ~153×76 m)",
    's2':        "S2 — 4-ary, Hilbert (s2-L16 leaf, ~142 m globally)",
}


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


def load_metadata(csv_path):
    """Read metadata.json next to the CSV. Returns {} if not present so
    legacy runs (pre-metadata) still plot cleanly with no subtitle info."""
    meta_path = os.path.join(os.path.dirname(csv_path), "metadata.json")
    if os.path.exists(meta_path):
        try:
            return json.load(open(meta_path))
        except Exception:
            pass
    return {}


def subtitle_from_metadata(meta):
    """Compact one-line subtitle naming the experimental conditions."""
    if not meta:
        return ""
    env  = meta.get("envelope", {})
    samp = meta.get("sampling", {})
    data = meta.get("data", {})
    pieces = []
    if data.get("table"):
        rows = data.get("rows")
        if isinstance(rows, int):
            pieces.append(f"table={data['table']} ({rows:,} rows)")
        else:
            pieces.append(f"table={data['table']}")
    shape = meta.get("shape")
    if shape == "box":
        pieces.append(f"box {env.get('side_km')}×{env.get('side_km')} km")
    elif shape == "circle":
        pieces.append(f"circle r={env.get('radius_km')} km")
    lons = samp.get("longitudes") or []
    if len(lons) == 1:
        pieces.append(f"lon={lons[0]}")
    elif lons:
        pieces.append(f"{len(lons)} lons {lons[0]}..{lons[-1]}")
    if samp.get("measured_runs"):
        pieces.append(f"{samp['measured_runs']} measured runs/point")
    return " • ".join(pieces)


def plot_absolute(data, ylabel, title, subtitle, out_path):
    """One PNG: per-engine line, absolute metric vs latitude.
    Annotates each gh and qz marker with its ratio to the s2 baseline at
    the same latitude, so the reader can see both magnitudes AND
    relative-cost numbers from one chart (same idiom as
    plot_cell_count.cells_vs_lat)."""
    fig, ax = plt.subplots(figsize=(10, 5.5))
    for sys_ in SYS_ORDER:
        if sys_ not in data:
            continue
        lats = sorted(data[sys_].keys())
        ys   = [data[sys_][l] for l in lats]
        color, marker = PALETTE[sys_]
        ax.plot(lats, ys, color=color, marker=marker, linewidth=2,
                markersize=7, label=ENGINE_LABEL.get(sys_, sys_))

    # Per-lat s2 lookup for ratio annotations
    s2_at = data.get('s2', {})
    # gh labels go above the marker (positive dy); qz labels go below
    # (negative dy) so the two lines' labels don't collide when gh ≈ qz.
    for sys_, dy in [('c_geohash', 8), ('qz', -14)]:
        if sys_ not in data:
            continue
        color, _ = PALETTE[sys_]
        lats = sorted(data[sys_].keys())
        for x in lats:
            y = data[sys_][x]
            if x not in s2_at or s2_at[x] == 0:
                continue
            ax.annotate(f"{y/s2_at[x]:.1f}×",
                        xy=(x, y), xytext=(3, dy),
                        textcoords="offset points",
                        fontsize=8, color=color, ha="left")

    ax.set_xlabel("Latitude (°)")
    ax.set_ylabel(ylabel)
    full_title = title + ("\n" + subtitle if subtitle else "")
    ax.set_title(full_title, fontsize=11)
    ax.grid(True, linestyle=':', alpha=0.5)
    ax.legend(loc='upper left', fontsize=9)
    fig.tight_layout()
    fig.savefig(out_path, dpi=130, bbox_inches='tight')
    plt.close(fig)
    print(f"  wrote {out_path}")


def plot_ratio(data, metric_label, title, subtitle, out_path):
    """One PNG: gh/s2 and qz/s2 ratio vs latitude, with N× annotations."""
    fig, ax = plt.subplots(figsize=(10, 5.5))
    ax.axhline(1.0, color='grey', linewidth=0.8, linestyle='--',
               label='parity (1×)')
    if 's2' not in data:
        ax.set_title(f"{title}\n(no s2 baseline in this run)", fontsize=11)
    else:
        s2_at = data['s2']
        for sys_ in SYS_ORDER:
            if sys_ == 's2' or sys_ not in data:
                continue
            lats   = sorted(l for l in data[sys_].keys() if l in s2_at)
            ratios = [data[sys_][l] / s2_at[l] for l in lats]
            color, marker = PALETTE[sys_]
            ax.plot(lats, ratios, color=color, marker=marker, linewidth=2,
                    markersize=7, label=f"{ENGINE_LABEL.get(sys_, sys_)} / s2")
            for x, y in zip(lats, ratios):
                ax.annotate(f"{y:.1f}×", xy=(x, y), xytext=(4, 4),
                            textcoords='offset points',
                            fontsize=8, color=color)
        full_title = title + ("\n" + subtitle if subtitle else "")
        ax.set_title(full_title, fontsize=11)
    ax.set_xlabel("Latitude (°)")
    ax.set_ylabel(f"Ratio of {metric_label} to S2  (>1 = engine slower than S2)")
    ax.grid(True, linestyle=':', alpha=0.5)
    ax.legend(loc='upper left', fontsize=9)
    fig.tight_layout()
    fig.savefig(out_path, dpi=130, bbox_inches='tight')
    plt.close(fig)
    print(f"  wrote {out_path}")


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

    meta = load_metadata(csv_path)
    subtitle = subtitle_from_metadata(meta)

    out_dir = os.path.dirname(csv_path)
    plot_absolute(by_exec,  "Median query execution time (ms)",
                  "Query execution time vs latitude", subtitle,
                  os.path.join(out_dir, "exec_ms.png"))
    plot_absolute(by_reads, "Median storage read requests (DocDB round-trips)",
                  "DocDB round-trips per query vs latitude", subtitle,
                  os.path.join(out_dir, "rpcs.png"))
    plot_ratio(by_exec,  "execution time",
               "Query execution time relative to S2", subtitle,
               os.path.join(out_dir, "exec_ms_ratio.png"))
    plot_ratio(by_reads, "round-trips",
               "DocDB round-trips relative to S2", subtitle,
               os.path.join(out_dir, "rpcs_ratio.png"))


if __name__ == "__main__":
    main()
