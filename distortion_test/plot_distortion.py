#!/usr/bin/env python3
"""
Plot the distortion sweep (LEG 1).

Reads distortion.csv from a run_<ts>/ dir and produces two PNGs:
  1. cells_vs_lat.png   -- absolute cell count vs latitude, one line per
                           system. Log y-axis.
  2. growth_vs_lat.png  -- normalized growth ratio (cells_at_lat /
                           cells_at_lat0) vs latitude. Linear y-axis.
                           This is the cleanest "gh balloons, S2 stays
                           bounded" picture.
"""
import csv
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def load_csv(path):
    rows = []
    with open(path) as f:
        for r in csv.DictReader(f):
            rows.append({
                "lat":     float(r["lat"]),
                "gh":      int(r["gh_cells"]),
                "s2":      int(r["s2_cells"]),
                "gh_ratio": float(r["gh_ratio_vs_lat0"]),
                "s2_ratio": float(r["s2_ratio_vs_lat0"]),
            })
    return rows


def plot_cells_vs_lat(rows, out_path):
    lats = [r["lat"] for r in rows]
    gh   = [r["gh"]  for r in rows]
    s2   = [r["s2"]  for r in rows]

    fig, ax = plt.subplots(figsize=(9, 6))
    ax.plot(lats, gh, marker="o", color="#a50026", linewidth=2.5,
            label="geohash (precision 7, ~152 m cells)")
    ax.plot(lats, s2, marker="s", color="#2166ac", linewidth=2.5,
            label="S2 (level 16, ~142 m cells)")
    ax.set_yscale("log")
    ax.set_xlabel("Latitude (°)")
    ax.set_ylabel("Cells in cover (log scale)")
    ax.set_title("LEG 1 -- Distortion: cells per query vs latitude\n"
                 "Same physical query (50 km × 50 km box at lon=7°), "
                 "fixed cell size in each system")
    ax.grid(True, which="both", alpha=0.3)
    ax.legend(loc="upper left")

    fig.tight_layout()
    fig.savefig(out_path, dpi=130)
    plt.close(fig)
    print(f"  wrote {out_path}")


def plot_growth_vs_lat(rows, out_path):
    lats = [r["lat"] for r in rows]
    gh_r = [r["gh_ratio"] for r in rows]
    s2_r = [r["s2_ratio"] for r in rows]

    fig, ax = plt.subplots(figsize=(9, 6))
    ax.plot(lats, gh_r, marker="o", color="#a50026", linewidth=2.5,
            label="geohash growth (relative to lat=0)")
    ax.plot(lats, s2_r, marker="s", color="#2166ac", linewidth=2.5,
            label="S2 growth (relative to lat=0)")
    ax.axhline(1.0, color="grey", linewidth=0.5, linestyle=":")
    ax.set_xlabel("Latitude (°)")
    ax.set_ylabel("Cell-count growth ratio  (cells / cells at lat=0)")
    ax.set_title("LEG 1 -- Distortion: cell-count growth normalized to lat=0\n"
                 "gh balloons; S2 stays bounded")
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
    rows = load_csv(csv_path)
    out_dir = os.path.dirname(csv_path)
    plot_cells_vs_lat(rows, os.path.join(out_dir, "cells_vs_lat.png"))
    plot_growth_vs_lat(rows, os.path.join(out_dir, "growth_vs_lat.png"))


if __name__ == "__main__":
    main()
