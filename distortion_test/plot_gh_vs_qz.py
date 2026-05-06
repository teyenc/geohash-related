#!/usr/bin/env python3
"""
Plot the gh-vs-qz adaptive sweep (LEG 3).

Reads gh_vs_qz.csv from a run_<ts>/ dir and produces two PNGs:
  1. cells_vs_size.png   -- median cell count vs query side, with
                            min/max band across the 4 longitudes. One
                            line per system. Log-log axes.
  2. ratio_vs_size.png   -- gh/qz ratio vs query side. Above 1.0 means
                            qz wins. Shows the structural advantage
                            magnitude per query size.
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

    # gh: median line + min/max band
    ax.plot(sides, [a["gh_med"] for a in agg], marker="o", color="#a50026",
            linewidth=2.5, label="geohash (32-ary tree, Z curve)")
    ax.fill_between(sides,
                    [a["gh_min"] for a in agg],
                    [a["gh_max"] for a in agg],
                    color="#a50026", alpha=0.15)

    # qz: median line + min/max band
    ax.plot(sides, [a["qz_med"] for a in agg], marker="s", color="#2166ac",
            linewidth=2.5, label="quadtree-Z (4-ary tree, Z curve)")
    ax.fill_between(sides,
                    [a["qz_min"] for a in agg],
                    [a["qz_max"] for a in agg],
                    color="#2166ac", alpha=0.15)

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel("Query half-width (km)")
    ax.set_ylabel("Cells in exact cover (log scale)")
    ax.set_title("LEG 3 -- gh vs qz cells per query at lat=0 (no distortion)\n"
                 "Same algorithm, same Z-order curve, matched cell shape;\n"
                 "only the tree branching factor differs (32 vs 4)")
    ax.grid(True, which="both", alpha=0.3)
    ax.legend(loc="upper left")

    fig.tight_layout()
    fig.savefig(out_path, dpi=130)
    plt.close(fig)
    print(f"  wrote {out_path}")


def plot_ratio_vs_size(agg, out_path):
    sides = [a["side"] for a in agg]
    ratios_med = [a["ratio_med"] for a in agg]
    ratios_min = [a["ratio_min"] for a in agg]
    ratios_max = [a["ratio_max"] for a in agg]

    fig, ax = plt.subplots(figsize=(10, 6))
    ax.plot(sides, ratios_med, marker="o", color="#1a9641",
            linewidth=2.5, label="median gh/qz ratio")
    ax.fill_between(sides, ratios_min, ratios_max,
                    color="#1a9641", alpha=0.18,
                    label="min/max across longitudes")
    ax.axhline(1.0, color="grey", linewidth=0.8, linestyle=":",
               label="parity (1×)")
    ax.set_xscale("log")
    ax.set_xlabel("Query half-width (km)")
    ax.set_ylabel("gh cells / qz cells   (>1 means qz wins)")
    ax.set_title("LEG 3 -- structural advantage of qz over gh, by query size\n"
                 "Aggregated across 4 anchor longitudes")
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
    plot_ratio_vs_size(agg, os.path.join(out_dir, "ratio_vs_size.png"))


if __name__ == "__main__":
    main()
