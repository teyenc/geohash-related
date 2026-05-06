#!/usr/bin/env python3
"""
Plot the gh-vs-qz adaptive sweep.

Reads gh_vs_qz.csv from a run_<ts>/ dir and produces:
  cells_vs_size.png  -- median cell count vs query side, one line per
                        system. Log-log axes.
"""
import csv
import os
import statistics
import sys
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def load_csv(path):
    rows = []
    with open(path) as f:
        for r in csv.DictReader(f):
            rows.append({
                "lon":      float(r["lon"]),
                "side_km":  float(r["side_km"]),
                "gh":       int(r["gh_cells"]),
                "qz":       int(r["qz_cells"]),
                "gh_over_qz": float(r["gh_over_qz"]),
            })
    return rows


def aggregate_per_side(rows):
    """Group rows by side_km; for each, aggregate across the 4 lons."""
    groups = defaultdict(lambda: {"gh": [], "qz": [], "ratios": []})
    for r in rows:
        groups[r["side_km"]]["gh"].append(r["gh"])
        groups[r["side_km"]]["qz"].append(r["qz"])
        groups[r["side_km"]]["ratios"].append(r["gh_over_qz"])
    sides = sorted(groups.keys())
    return [
        {
            "side":  s,
            "gh_med": statistics.median(groups[s]["gh"]),
            "gh_min": min(groups[s]["gh"]),
            "gh_max": max(groups[s]["gh"]),
            "qz_med": statistics.median(groups[s]["qz"]),
            "qz_min": min(groups[s]["qz"]),
            "qz_max": max(groups[s]["qz"]),
            "ratio_med": statistics.median(groups[s]["ratios"]),
            "ratio_min": min(groups[s]["ratios"]),
            "ratio_max": max(groups[s]["ratios"]),
        }
        for s in sides
    ]


def plot_cells_vs_size(agg, out_path):
    sides = [a["side"] for a in agg]
    fig, ax = plt.subplots(figsize=(10, 6))

    ax.plot(sides, [a["gh_med"] for a in agg], marker="o", color="#a50026",
            linewidth=2.5, label="geohash (32-ary tree, Z curve)")
    ax.plot(sides, [a["qz_med"] for a in agg], marker="s", color="#2166ac",
            linewidth=2.5, label="quadtree-Z (4-ary tree, Z curve)")

    ax.set_xlabel("Query half-width (km)")
    ax.set_ylabel("Cells in exact cover")
    ax.set_title("Cells per query: geohash vs quadtree-Z, at lat=0\n"
                 "(median across 4 anchor longitudes; same algorithm "
                 "and Z-order curve, only tree branching factor differs)")
    ax.grid(True, which="both", alpha=0.3)
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
            p = os.path.join(results, cand, "gh_vs_qz.csv")
            if os.path.exists(p):
                csv_path = p
                break
        else:
            print("no gh_vs_qz.csv found in results/run_*/", file=sys.stderr)
            sys.exit(1)
    print(f"reading {csv_path}")
    rows = load_csv(csv_path)
    agg  = aggregate_per_side(rows)
    out_dir = os.path.dirname(csv_path)
    plot_cells_vs_size(agg, os.path.join(out_dir, "cells_vs_size.png"))


if __name__ == "__main__":
    main()
