#!/usr/bin/env python3
"""
Tabulate a radius_sweep CSV as two markdown tables:

  1. <stem>_latency.md  — latency table, median ms across longitudes
  2. <stem>_cells.md    — cell-count table, median across longitudes

Cells show the absolute median across the 4 longitudes per (lat, r). Raw
values; readers can eyeball the trend across rows without log scaling.

Usage:
  python3 tabulate_results.py [path/to/csv]

If no path is given, the latest CSV in distortion_test/results/ is used.
"""

import csv
import glob
import os
import sys
from collections import defaultdict
import statistics


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
                "lat":     float(r["lat"]),
                "lon":     float(r["lon"]),
                "r":       float(r["radius_km"]),
                "gh_cells": int(r["gh_cells"]),
                "s2_cells": int(r["s2_cells"]),
                "gh_ms":   float(r["gh_ms"]),
                "s2_ms":   float(r["s2_ms"]),
            })
    return rows


def median_per_lat_r(rows, key):
    """key in ('gh_ms', 's2_ms', 'gh_cells', 's2_cells')."""
    out = defaultdict(lambda: defaultdict(list))   # out[r][lat] = [values]
    for r in rows:
        out[r["r"]][r["lat"]].append(r[key])
    return {
        r_val: {lat: statistics.median(vs) for lat, vs in lat_map.items()}
        for r_val, lat_map in out.items()
    }


def fmt_value(value, is_int):
    """Format a cell as the raw number, with thousands separators."""
    if is_int:
        return f"{int(round(value)):,}"
    return f"{value:,.0f}"


def render_table(title, gh_med, s2_med, lats, radii, unit, is_int):
    """Build a markdown table of raw median values."""
    cols = []
    for r in radii:
        cols.append(("gh", r))
        cols.append(("s2", r))

    headers = ["lat"]
    for scheme, r in cols:
        headers.append(f"{scheme} r={int(r)}km {unit}")

    rows_md = []
    rows_md.append("| " + " | ".join(headers) + " |")
    rows_md.append("|" + "|".join(["---"] * len(headers)) + "|")

    for lat in lats:
        row = [f"{int(lat)}°"]
        for scheme, r in cols:
            meds = gh_med if scheme == "gh" else s2_med
            val = meds.get(r, {}).get(lat, 0)
            row.append(fmt_value(val, is_int))
        rows_md.append("| " + " | ".join(row) + " |")

    out = [f"## {title}\n", *rows_md, ""]
    return "\n".join(out)


def main():
    here = os.path.dirname(os.path.realpath(__file__))
    csv_path = sys.argv[1] if len(sys.argv) > 1 else find_latest_csv(here)
    rows = load(csv_path)
    if not rows:
        sys.exit(f"No rows found in {csv_path}")

    lats = sorted({r["lat"] for r in rows})
    radii = sorted({r["r"] for r in rows})

    gh_ms_med = median_per_lat_r(rows, "gh_ms")
    s2_ms_med = median_per_lat_r(rows, "s2_ms")
    gh_cells_med = median_per_lat_r(rows, "gh_cells")
    s2_cells_med = median_per_lat_r(rows, "s2_cells")

    stem = os.path.splitext(csv_path)[0]
    print(f"reading {csv_path} ({len(rows)} rows)\n")

    latency_md = render_table(
        "Latency by latitude (median ms across longitudes)",
        gh_ms_med, s2_ms_med, lats, radii, "(ms)", is_int=False)
    cells_md = render_table(
        "Cell count by latitude (median across longitudes)",
        gh_cells_med, s2_cells_med, lats, radii, "(cells)", is_int=True)

    # Print to stdout
    print(latency_md)
    print(cells_md)

    # Save .md alongside the CSV
    with open(stem + "_latency.md", "w") as fh:
        fh.write(latency_md + "\n")
    with open(stem + "_cells.md", "w") as fh:
        fh.write(cells_md + "\n")
    print(f"# wrote {stem}_latency.md")
    print(f"# wrote {stem}_cells.md")


if __name__ == "__main__":
    main()
