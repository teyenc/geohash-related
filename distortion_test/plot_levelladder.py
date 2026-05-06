#!/usr/bin/env python3
"""
Visualize the level-ladder sweep (lat=0, equator, no shape distortion).

Reads the cell-count CSV from a run_<ts>/ directory and produces two
plots:

  1. cells vs query side, log y -- shows gh growing quadratically within
     each precision band and S2 bounded by max_cells.
  2. (cells, over_fetch) scatter -- shows the operating-point trade-off:
     gh has to pick between (few cells, high over_fetch) and (low
     over_fetch, many cells); S2 hits the sweet-spot corner with both
     bounded.

Over-fetch on the scatter is computed analytically from the cell sizes
at the equator (gh: known linear per precision; S2: estimated from the
typical coverer over-fetch ratio with the given max_cells budget). The
analytic numbers line up with the measured 1.4x / 1.3x / 2.0x from the
partial DB run for s2@8 at sides 3 / 4 / 5 km.

Usage:
    python3 plot_levelladder.py [path/to/levelladder_sweep.csv]
"""
import csv
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# Cell linear / area at the equator. Numbers from the bit math in
# c_geohash.c:62-67 (gh) and the S2 face_size / 2^level approximation (s2).
GH_CELL_AREA_KM2 = {
    3: 156.0 * 156.0,        # 156 km square cells
    4:  39.0 *  19.0,        # rectangular -- 4-bit / 8-bit alternation
    5:   4.9 *   4.9,
    6:   1.22 *  0.61,
    7:   0.152 * 0.152,
}

# S2 over-fetch is roughly constant across sizes for a fixed max_cells
# budget (the coverer adapts cell size to the query). Values calibrated
# against the partial DB run: s2@8 measured 1.4x / 1.3x / 2.0x at sides
# 3 / 4 / 5 km, so ~1.6x typical. s2@64 measured 1.1x / 1.1x / 1.1x.
S2_TYPICAL_OVERFETCH = {8: 1.6, 64: 1.1}

# Measured over-fetch from the partial run that did finish before timing out.
# Used for ground-truth points overlaid on the analytic curves.
MEASURED = {
    # (scheme, side_km) -> over_fetch
    ("gh3",   3): 477.0,
    ("gh4",   3):  44.1, ("gh4",   4):  52.3, ("gh4",   5):  31.4,
    ("gh5",   3):   2.7, ("gh5",   4):   2.4, ("gh5",   5):   2.9,
    ("gh6",   3):   1.2, ("gh6",   4):   1.4, ("gh6",   5):   1.2,
    ("gh7",   3):   1.1, ("gh7",   4):   1.1, ("gh7",   5):   1.0,
    ("s2_8",  3):   1.4, ("s2_8",  4):   1.3, ("s2_8",  5):   2.0,
    ("s2_64", 3):   1.1, ("s2_64", 4):   1.1, ("s2_64", 5):   1.1,
}


def overfetch(scheme, cells, side_km):
    """Analytic over-fetch given the cell count for a 2*side_km box at
    the equator. Assumes uniform point density inside the cluster."""
    query_area = (2.0 * side_km) ** 2
    if scheme.startswith("gh"):
        p = int(scheme[2:])
        return cells * GH_CELL_AREA_KM2[p] / query_area
    if scheme.startswith("s2_"):
        budget = int(scheme[3:])
        return S2_TYPICAL_OVERFETCH[budget]
    raise ValueError(scheme)


def load_csv(path):
    """Returns dict[scheme] -> list of (side_km, cells)."""
    out = {sch: [] for sch in
           ["gh3", "gh4", "gh5", "gh6", "gh7", "s2_8", "s2_64"]}
    csv_to_scheme = {"gh3": "gh3", "gh4": "gh4", "gh5": "gh5",
                     "gh6": "gh6", "gh7": "gh7",
                     "s2_def": "s2_8", "s2_fair": "s2_64"}
    with open(path) as f:
        for row in csv.DictReader(f):
            side = float(row["side_km"])
            for csv_col, sch in csv_to_scheme.items():
                if csv_col in row:
                    out[sch].append((side, int(row[csv_col])))
    return out


# ----------------------------------------------------------------------------
# plot 1 -- cells vs side, log y
# ----------------------------------------------------------------------------
def plot_cells_vs_side(data, out_path):
    fig, ax = plt.subplots(figsize=(10, 6))
    color_gh = {"gh3": "#fee08b", "gh4": "#fdae61",
                "gh5": "#f46d43", "gh6": "#d73027", "gh7": "#a50026"}
    color_s2 = {"s2_8": "#2166ac", "s2_64": "#4393c3"}

    for sch in ["gh3", "gh4", "gh5", "gh6", "gh7"]:
        pts = data[sch]
        if not pts: continue
        sides, cells = zip(*pts)
        label = f"gh@p{sch[2]} ({GH_CELL_AREA_KM2[int(sch[2])]**0.5:.2g} km cells)"
        ax.plot(sides, cells, marker="o", color=color_gh[sch],
                linewidth=2, label=label)

    for sch in ["s2_8", "s2_64"]:
        pts = data[sch]
        if not pts: continue
        sides, cells = zip(*pts)
        label = f"S2 max_cells={sch[3:]}"
        ax.plot(sides, cells, marker="s", color=color_s2[sch],
                linewidth=2.5, label=label)

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel("Query rectangle half-width (km)")
    ax.set_ylabel("Cover cell count")
    ax.set_title("Cell count vs query size at lat=0 (no distortion, lon=7°)\n"
                 "gh@pN: fixed precision (with merge); S2: adaptive coverer "
                 "with max_cells budget")
    ax.grid(True, which="both", alpha=0.3)
    ax.legend(loc="upper left", fontsize=9, ncol=2)

    fig.tight_layout()
    fig.savefig(out_path, dpi=130)
    plt.close(fig)
    print(f"  wrote {out_path}")


# ----------------------------------------------------------------------------
# plot 2 -- (cells, over_fetch) operating-point scatter
# ----------------------------------------------------------------------------
def plot_operating_point(data, out_path):
    fig, ax = plt.subplots(figsize=(10, 6.5))

    color_gh = {"gh3": "#fee08b", "gh4": "#fdae61",
                "gh5": "#f46d43", "gh6": "#d73027", "gh7": "#a50026"}
    color_s2 = {"s2_8": "#2166ac", "s2_64": "#4393c3"}

    # Analytic curves: each scheme draws a line of (cells, over_fetch) as
    # side varies from 3 km to 224 km.
    for sch in ["gh3", "gh4", "gh5", "gh6", "gh7"]:
        pts = data[sch]
        if not pts: continue
        cells_arr = []
        over_arr = []
        for side, cells in pts:
            if cells <= 0: continue
            cells_arr.append(cells)
            over_arr.append(overfetch(sch, cells, side))
        ax.plot(cells_arr, over_arr, marker="o", color=color_gh[sch],
                linewidth=1.5, alpha=0.55, markersize=5,
                label=f"gh@p{sch[2]}")

    for sch in ["s2_8", "s2_64"]:
        pts = data[sch]
        if not pts: continue
        cells_arr = []
        over_arr = []
        for side, cells in pts:
            if cells <= 0: continue
            cells_arr.append(cells)
            over_arr.append(overfetch(sch, cells, side))
        ax.plot(cells_arr, over_arr, marker="s", color=color_s2[sch],
                linewidth=2.5, markersize=10,
                label=f"S2 max_cells={sch[3:]}")

    # Overlay measured ground-truth points (X markers) for the sides we
    # did get DB measurements for.
    for (sch, side), over in MEASURED.items():
        pts = dict(data.get(sch, []))
        if side not in pts: continue
        cells = pts[side]
        ax.plot(cells, over, marker="x", color="black",
                markersize=10, mew=2, zorder=5)

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel("Cover cell count  (= number of B-tree probes / ranges)")
    ax.set_ylabel("Over-fetch ratio  (candidates / true_hits)")
    ax.set_title("Operating-point trade-off at lat=0\n"
                 "Each point = one query size on one scheme; "
                 "✕ = DB-measured (rest analytic from cell sizes)")
    ax.grid(True, which="both", alpha=0.3)

    # Sweet-spot annotation
    ax.axhspan(1.0, 2.0, color="lightgreen", alpha=0.10)
    ax.text(2, 1.05, "tight cover", color="green", fontsize=9, alpha=0.7)
    ax.axvspan(1, 16, color="lightblue", alpha=0.10)
    ax.text(1.05, 0.7, "few B-tree probes", color="blue", fontsize=9,
            alpha=0.7, rotation=90, va="bottom")

    ax.legend(loc="lower left", fontsize=9, ncol=2)
    fig.tight_layout()
    fig.savefig(out_path, dpi=130)
    plt.close(fig)
    print(f"  wrote {out_path}")


def main():
    if len(sys.argv) > 1:
        csv_path = sys.argv[1]
    else:
        # Default: latest run_*/ under results/
        here = os.path.dirname(os.path.realpath(__file__))
        results_dir = os.path.join(here, "results")
        runs = sorted(d for d in os.listdir(results_dir) if d.startswith("run_"))
        if not runs:
            print("no run_*/ directories found in results/", file=sys.stderr)
            sys.exit(1)
        # find most recent run that has levelladder_sweep.csv with all
        # fixed-precision columns
        for cand in reversed(runs):
            p = os.path.join(results_dir, cand, "levelladder_sweep.csv")
            if not os.path.exists(p):
                continue
            with open(p) as f:
                hdr = f.readline().strip().split(",")
            if "gh3" in hdr and "s2_def" in hdr:
                csv_path = p
                break
        else:
            print("no levelladder_sweep.csv with the expected columns found",
                  file=sys.stderr)
            sys.exit(1)
    print(f"reading {csv_path}")
    data = load_csv(csv_path)

    out_dir = os.path.dirname(csv_path)
    plot_cells_vs_side(data, os.path.join(out_dir, "cells_vs_side.png"))
    plot_operating_point(data, os.path.join(out_dir, "operating_point.png"))


if __name__ == "__main__":
    main()
