#!/usr/bin/env python3
"""
Plot results from a radius_sweep CSV.

Two plots, each saved as a PNG next to the input CSV:

  1. <stem>_latency.png — latency vs latitude, one line per (scheme, radius)
                          using median across longitudes per (lat, r) cell.
                          Log y-axis. Shows the "S2 flat / gh grows" thesis.

  2. <stem>_cells.png   — cell-count (= number of B-tree range scans the
                          query has to issue) vs latitude. Same layout as
                          plot 1 but on the cell-count axis. Shows the
                          structural cause of the latency gap: gh has to
                          scan many more cells at high latitude; S2 doesn't.

Usage:
  python3 plot_results.py [path/to/csv]

If no path is given, the latest CSV in distortion_test/results/ is used.
"""

import csv
import glob
import os
import sys
from collections import defaultdict
import statistics

import matplotlib

matplotlib.use("Agg")  # headless / no display
import matplotlib.pyplot as plt


def find_latest_csv(here):
    pattern = os.path.join(here, "results", "radius_sweep_*.csv")
    candidates = sorted(glob.glob(pattern))
    if not candidates:
        sys.exit(f"No CSV found matching {pattern}")
    return candidates[-1]


def load(csv_path):
    rows = []
    with open(csv_path, "r", newline="") as fh:
        for r in csv.DictReader(fh):
            rows.append({
                "lat":   float(r["lat"]),
                "lon":   float(r["lon"]),
                "r":     float(r["radius_km"]),
                "gh_cells": int(r["gh_cells"]),
                "s2_cells": int(r["s2_cells"]),
                "gh_ms": float(r["gh_ms"]),
                "s2_ms": float(r["s2_ms"]),
                "cells_ratio": float(r["cells_gh_over_s2"]),
                "time_ratio":  float(r["time_gh_over_s2"]),
            })
    return rows


def plot_latency_vs_lat(rows, out_path):
    """
    For each (scheme, radius), plot median latency across the 4 longitudes
    at each latitude. Log y-axis since gh values span >2 orders of magnitude.
    """
    by_radius_scheme = defaultdict(lambda: defaultdict(list))
    for r in rows:
        by_radius_scheme[("gh", r["r"])][r["lat"]].append(r["gh_ms"])
        by_radius_scheme[("s2", r["r"])][r["lat"]].append(r["s2_ms"])

    fig, ax = plt.subplots(figsize=(8, 5.5))
    styles = {
        ("gh", 25.0): {"color": "C3", "marker": "o",
                       "linestyle": "-",  "label": "geohash, r=25 km"},
        ("gh", 75.0): {"color": "C3", "marker": "s",
                       "linestyle": "--", "label": "geohash, r=75 km"},
        ("s2", 25.0): {"color": "C0", "marker": "o",
                       "linestyle": "-",  "label": "S2, r=25 km"},
        ("s2", 75.0): {"color": "C0", "marker": "s",
                       "linestyle": "--", "label": "S2, r=75 km"},
    }
    for key, latmap in by_radius_scheme.items():
        lats = sorted(latmap)
        meds = [statistics.median(latmap[l]) for l in lats]
        ax.plot(lats, meds, **styles[key], linewidth=2, markersize=7)

    ax.set_xlabel("query latitude (°)")
    ax.set_ylabel("median latency across 4 longitudes (ms, log)")
    ax.set_yscale("log")
    ax.set_title("Latency vs latitude — geohash grows, S2 stays flat")
    ax.grid(True, which="both", linestyle=":", alpha=0.4)
    ax.legend(loc="upper left")
    fig.tight_layout()
    fig.savefig(out_path, dpi=120)
    plt.close(fig)
    print(f"  wrote {out_path}")


def plot_cells_vs_lat(rows, out_path):
    """
    Cell-count vs latitude, one line per (scheme, radius). Same shape as
    the latency plot but on the cells axis — visually shows the structural
    cause of the latency gap: gh emits many more cells at high latitude;
    S2 doesn't.
    """
    by_radius_scheme = defaultdict(lambda: defaultdict(list))
    for r in rows:
        by_radius_scheme[("gh", r["r"])][r["lat"]].append(r["gh_cells"])
        by_radius_scheme[("s2", r["r"])][r["lat"]].append(r["s2_cells"])

    fig, ax = plt.subplots(figsize=(8, 5.5))
    styles = {
        ("gh", 25.0): {"color": "C3", "marker": "o",
                       "linestyle": "-",  "label": "geohash, r=25 km"},
        ("gh", 75.0): {"color": "C3", "marker": "s",
                       "linestyle": "--", "label": "geohash, r=75 km"},
        ("s2", 25.0): {"color": "C0", "marker": "o",
                       "linestyle": "-",  "label": "S2, r=25 km"},
        ("s2", 75.0): {"color": "C0", "marker": "s",
                       "linestyle": "--", "label": "S2, r=75 km"},
    }
    for key, latmap in by_radius_scheme.items():
        lats = sorted(latmap)
        meds = [statistics.median(latmap[l]) for l in lats]
        ax.plot(lats, meds, **styles[key], linewidth=2, markersize=7)

    ax.set_xlabel("query latitude (°)")
    ax.set_ylabel("median cell count across 4 longitudes (log)")
    ax.set_yscale("log")
    ax.set_title("Cell count vs latitude — geohash grows, S2 stays flat")
    ax.grid(True, which="both", linestyle=":", alpha=0.4)
    ax.legend(loc="upper left")
    fig.tight_layout()
    fig.savefig(out_path, dpi=120)
    plt.close(fig)
    print(f"  wrote {out_path}")


def main():
    here = os.path.dirname(os.path.realpath(__file__))
    csv_path = sys.argv[1] if len(sys.argv) > 1 else find_latest_csv(here)
    rows = load(csv_path)
    if not rows:
        sys.exit(f"No rows found in {csv_path}")

    stem = os.path.splitext(csv_path)[0]
    print(f"reading {csv_path} ({len(rows)} rows)")
    plot_latency_vs_lat(rows, stem + "_latency.png")
    plot_cells_vs_lat(rows, stem + "_cells.png")


if __name__ == "__main__":
    main()
