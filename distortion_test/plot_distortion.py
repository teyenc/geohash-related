#!/usr/bin/env python3
"""
Plot the distortion sweep.

Reads distortion.csv from a run_<ts>/ dir and produces two PNGs:
  1. cells_vs_lat.png   -- median absolute cell count vs latitude,
                           one line per system. Linear y-axis.
  2. growth_vs_lat.png  -- median growth ratio (cells_at_lat /
                           cells_at_lat0) vs latitude, one line per
                           system. Linear y-axis.

CSV format: rows of (lat, lon, gh_cells, s2_cells). Multiple lons per
lat -- this script aggregates by taking the median across longitudes
for each (lat, system).
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
    by_lat_s2 = defaultdict(list)
    with open(path) as f:
        for r in csv.DictReader(f):
            lat = float(r["lat"])
            by_lat_gh[lat].append(int(r["gh_cells"]))
            by_lat_s2[lat].append(int(r["s2_cells"]))
    lats = sorted(by_lat_gh.keys())

    gh_baseline = statistics.median(by_lat_gh[lats[0]]) or 1
    s2_baseline = statistics.median(by_lat_s2[lats[0]]) or 1

    return [
        {
            "lat":      lat,
            "gh_med":   statistics.median(by_lat_gh[lat]),
            "s2_med":   statistics.median(by_lat_s2[lat]),
            "gh_ratio": statistics.median(by_lat_gh[lat]) / gh_baseline,
            "s2_ratio": statistics.median(by_lat_s2[lat]) / s2_baseline,
        }
        for lat in lats
    ]


def plot_cells_vs_lat(agg, out_path):
    lats = [a["lat"] for a in agg]
    gh   = [a["gh_med"] for a in agg]
    s2   = [a["s2_med"] for a in agg]

    fig, ax = plt.subplots(figsize=(10, 6))
    ax.plot(lats, gh, marker="o", color="#a50026", linewidth=2.5,
            label="geohash (precision 7, ~152 m cells)")
    ax.plot(lats, s2, marker="s", color="#2166ac", linewidth=2.5,
            label="S2 (level 16, ~142 m cells)")
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
    lats = [a["lat"] for a in agg]
    gh_r = [a["gh_ratio"] for a in agg]
    s2_r = [a["s2_ratio"] for a in agg]

    fig, ax = plt.subplots(figsize=(10, 6))
    ax.plot(lats, gh_r, marker="o", color="#a50026", linewidth=2.5,
            label="geohash growth (relative to lat=0)")
    ax.plot(lats, s2_r, marker="s", color="#2166ac", linewidth=2.5,
            label="S2 growth (relative to lat=0)")
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
        for cand in reversed(runs):
            p = os.path.join(results, cand, "distortion.csv")
            if os.path.exists(p):
                csv_path = p
                break
        else:
            print("no distortion.csv found in results/run_*/", file=sys.stderr)
            sys.exit(1)
    print(f"reading {csv_path}")
    agg = load_and_aggregate(csv_path)
    out_dir = os.path.dirname(csv_path)
    plot_cells_vs_lat (agg, os.path.join(out_dir, "cells_vs_lat.png"))
    plot_growth_vs_lat(agg, os.path.join(out_dir, "growth_vs_lat.png"))


if __name__ == "__main__":
    main()
