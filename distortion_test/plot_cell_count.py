#!/usr/bin/env python3
"""
Plot the cell-count sweep produced by cell_count_sweep.py.

Reads cell_count.csv from a run_<ts>/ dir and produces two PNGs:
  1. cells_vs_lat.png   -- median absolute cell count vs latitude,
                           one line per engine. Linear y-axis.
  2. growth_vs_lat.png  -- median growth ratio (cells_at_lat /
                           cells_at_lat0) vs latitude, one line per
                           engine. Linear y-axis.

CSV format: rows of (lat, lon, gh_cells, s2_cells). Multiple lons per
lat -- this script aggregates by taking the median across longitudes
for each (lat, engine). Blank cells (from --skip-gh / --skip-s2 runs)
are ignored.
"""
import csv
import os
import statistics
import sys
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def load_and_aggregate(path):
    """Returns sorted list of {lat, gh_med, s2_med, gh_ratio, s2_ratio}."""
    by_lat_gh = defaultdict(list)
    by_lat_qz = defaultdict(list)
    by_lat_s2 = defaultdict(list)
    with open(path) as f:
        for r in csv.DictReader(f):
            lat = float(r["lat"])
            # Skip blank cells — a --skip-* run leaves the corresponding
            # column empty. Older CSVs (pre-qz) won't have qz_cells; tolerate.
            if r.get("gh_cells", "").strip():
                by_lat_gh[lat].append(int(r["gh_cells"]))
            if r.get("qz_cells", "").strip():
                by_lat_qz[lat].append(int(r["qz_cells"]))
            if r.get("s2_cells", "").strip():
                by_lat_s2[lat].append(int(r["s2_cells"]))
    lats = sorted(set(by_lat_gh.keys()) | set(by_lat_qz.keys())
                  | set(by_lat_s2.keys()))

    gh_baseline = (statistics.median(by_lat_gh[lats[0]])
                   if by_lat_gh.get(lats[0]) else 1) or 1
    qz_baseline = (statistics.median(by_lat_qz[lats[0]])
                   if by_lat_qz.get(lats[0]) else 1) or 1
    s2_baseline = (statistics.median(by_lat_s2[lats[0]])
                   if by_lat_s2.get(lats[0]) else 1) or 1

    rows = []
    for lat in lats:
        gh_med = statistics.median(by_lat_gh[lat]) if by_lat_gh.get(lat) else None
        qz_med = statistics.median(by_lat_qz[lat]) if by_lat_qz.get(lat) else None
        s2_med = statistics.median(by_lat_s2[lat]) if by_lat_s2.get(lat) else None
        rows.append({
            "lat":      lat,
            "gh_med":   gh_med,
            "qz_med":   qz_med,
            "s2_med":   s2_med,
            "gh_ratio": gh_med / gh_baseline if gh_med is not None else None,
            "qz_ratio": qz_med / qz_baseline if qz_med is not None else None,
            "s2_ratio": s2_med / s2_baseline if s2_med is not None else None,
        })
    return rows


def plot_cells_vs_lat(agg, out_path):
    # Build per-engine series, dropping (lat, None) gaps so a partial run
    # (--skip-*) plots cleanly with no missing-data warnings.
    gh_lats = [a["lat"] for a in agg if a["gh_med"] is not None]
    gh_ys   = [a["gh_med"] for a in agg if a["gh_med"] is not None]
    qz_lats = [a["lat"] for a in agg if a["qz_med"] is not None]
    qz_ys   = [a["qz_med"] for a in agg if a["qz_med"] is not None]
    s2_lats = [a["lat"] for a in agg if a["s2_med"] is not None]
    s2_ys   = [a["s2_med"] for a in agg if a["s2_med"] is not None]

    fig, ax = plt.subplots(figsize=(10, 6))
    if gh_ys:
        ax.plot(gh_lats, gh_ys, marker="o", color="#a50026", linewidth=2.5,
                label="geohash — 32-ary, Z-order (precision 7, ~152 m cells)")
    if qz_ys:
        ax.plot(qz_lats, qz_ys, marker="D", color="#f46d43", linewidth=2.5,
                label="quadtree-Z — 4-ary, Z-order (level 17, ~306×153 m)")
    if s2_ys:
        ax.plot(s2_lats, s2_ys, marker="s", color="#2166ac", linewidth=2.5,
                label="S2 — 4-ary, Hilbert (level 16, ~142 m cells)")
    ax.set_xlabel("Latitude (°)")
    ax.set_ylabel("Cells in cover")
    ax.set_title("Cells per query vs latitude\n"
                 "(median across 4 anchor longitudes; "
                 "50 km × 50 km box, fixed cell size in each system)")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="upper left")

    fig.tight_layout()
    fig.savefig(out_path, dpi=130)
    plt.close(fig)
    print(f"  wrote {out_path}")


def plot_growth_vs_lat(agg, out_path):
    gh_lats = [a["lat"] for a in agg if a["gh_ratio"] is not None]
    gh_ys   = [a["gh_ratio"] for a in agg if a["gh_ratio"] is not None]
    qz_lats = [a["lat"] for a in agg if a["qz_ratio"] is not None]
    qz_ys   = [a["qz_ratio"] for a in agg if a["qz_ratio"] is not None]
    s2_lats = [a["lat"] for a in agg if a["s2_ratio"] is not None]
    s2_ys   = [a["s2_ratio"] for a in agg if a["s2_ratio"] is not None]

    fig, ax = plt.subplots(figsize=(10, 6))
    if gh_ys:
        ax.plot(gh_lats, gh_ys, marker="o", color="#a50026", linewidth=2.5,
                label="geohash growth (32-ary, Z-order)")
    if qz_ys:
        ax.plot(qz_lats, qz_ys, marker="D", color="#f46d43", linewidth=2.5,
                label="quadtree-Z growth (4-ary, Z-order)")
    if s2_ys:
        ax.plot(s2_lats, s2_ys, marker="s", color="#2166ac", linewidth=2.5,
                label="S2 growth (4-ary, Hilbert)")
    ax.axhline(1.0, color="grey", linewidth=0.5, linestyle=":")
    ax.set_xlabel("Latitude (°)")
    ax.set_ylabel("Cell-count growth ratio  (cells / cells at lat=0)")
    ax.set_title("Cell-count growth with latitude, normalized to lat=0\n"
                 "(median across 4 anchor longitudes)")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="upper left")

    fig.tight_layout()
    fig.savefig(out_path, dpi=130)
    plt.close(fig)
    print(f"  wrote {out_path}")


def main():
    if len(sys.argv) > 1:
        csv_path = sys.argv[1]
    else:
        here = os.path.dirname(os.path.realpath(__file__))
        results = os.path.join(here, "results")
        runs = sorted(d for d in os.listdir(results) if d.startswith("run_"))
        # Accept either the new name (cell_count.csv) or the legacy name
        # (distortion.csv) so older result folders still plot.
        for cand in reversed(runs):
            for fname in ("cell_count.csv", "distortion.csv"):
                p = os.path.join(results, cand, fname)
                if os.path.exists(p):
                    csv_path = p
                    break
            else:
                continue
            break
        else:
            print("no cell_count.csv (or legacy distortion.csv) found in "
                  "results/run_*/", file=sys.stderr)
            sys.exit(1)
    print(f"reading {csv_path}")
    agg = load_and_aggregate(csv_path)
    out_dir = os.path.dirname(csv_path)
    plot_cells_vs_lat (agg, os.path.join(out_dir, "cells_vs_lat.png"))
    plot_growth_vs_lat(agg, os.path.join(out_dir, "growth_vs_lat.png"))


if __name__ == "__main__":
    main()
