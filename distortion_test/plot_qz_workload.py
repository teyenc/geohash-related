#!/usr/bin/env python3
"""
Visualize the QZ vs GH workload.

The workload is NOT random -- it's 7 concentric rectangles centered at
(lat=0, lon=7), with half-widths [3, 5, 10, 20, 40, 80, 160] km. Lat=0
chosen to strip out shape distortion; lon=7 chosen because it doesn't
fall on any clean fraction of the geohash or quadtree-Z grid (so neither
side benefits from grid alignment).

Two panels:
  1. The 7 query rectangles overlaid, labeled by half-width.
  2. The 80 km query overlaid with the cell grids gh-4 / qz-L10 share
     (matched cell shape, 0.352 deg lon x 0.176 deg lat) so you can
     SEE the merging-granularity difference.
"""
import math
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as patches

LAT = 0
LON = 7.0
SIDE_KM = [3, 5, 10, 20, 40, 80, 160]
EARTH_R_KM = 6371.0088


def rect_bbox_deg(lat, lon, side_km):
    a = side_km / EARTH_R_KM
    phi = math.radians(lat)
    dlat = math.degrees(a)
    dlon = math.degrees(math.asin(math.sin(a) / math.cos(phi)))
    return (lon - dlon, lat - dlat, lon + dlon, lat + dlat)


def panel_workload(ax):
    """Panel 1: all 7 query rectangles, nested."""
    cmap = plt.cm.viridis
    colors = [cmap(i / (len(SIDE_KM) - 1)) for i in range(len(SIDE_KM))]
    # Largest first so smaller ones stack on top
    for side, color in sorted(zip(SIDE_KM, colors), key=lambda t: -t[0]):
        mn_lon, mn_lat, mx_lon, mx_lat = rect_bbox_deg(LAT, LON, side)
        rect = patches.Rectangle(
            (mn_lon, mn_lat), mx_lon - mn_lon, mx_lat - mn_lat,
            linewidth=1.5, edgecolor=color, facecolor=color, alpha=0.18,
            label=f"{side} km half-width")
        ax.add_patch(rect)
    # Center marker
    ax.plot(LON, LAT, "k+", markersize=12, mew=2)
    ax.text(LON + 0.05, LAT + 0.05, f"({LAT}°, {LON}°)",
            fontsize=9, color="black")
    # Equator line
    ax.axhline(0, color="grey", linewidth=0.5, linestyle=":")

    # Bound to largest rectangle plus margin
    big_lon = max(rect_bbox_deg(LAT, LON, max(SIDE_KM))[2] - LON,
                  LON - rect_bbox_deg(LAT, LON, max(SIDE_KM))[0])
    big_lat = max(rect_bbox_deg(LAT, LON, max(SIDE_KM))[3] - LAT,
                  LAT - rect_bbox_deg(LAT, LON, max(SIDE_KM))[1])
    margin = max(big_lon, big_lat) * 0.15
    ax.set_xlim(LON - big_lon - margin, LON + big_lon + margin)
    ax.set_ylim(LAT - big_lat - margin, LAT + big_lat + margin)
    ax.set_aspect("equal", "box")
    ax.set_xlabel("longitude (°)")
    ax.set_ylabel("latitude (°)")
    ax.set_title(f"Workload: 7 concentric query rectangles at "
                 f"(lat={LAT}°, lon={LON}°)\n"
                 f"All centered, only the half-width varies: "
                 f"{SIDE_KM} km")
    ax.legend(loc="upper right", fontsize=7)
    ax.grid(True, alpha=0.3)


def cells_at_level(min_lon, min_lat, max_lon, max_lat, level):
    """Enumerate all (cell_min_lon, cell_min_lat, cell_max_lon, cell_max_lat)
    cells at qz level (= gh-2L) that intersect the bbox."""
    side = 1 << level
    lon_step = 360.0 / side
    lat_step = 180.0 / side
    min_x = int(math.floor((min_lon + 180.0) / 360.0 * side))
    max_x = int(math.floor((max_lon + 180.0) / 360.0 * side))
    min_y = int(math.floor((min_lat +  90.0) / 180.0 * side))
    max_y = int(math.floor((max_lat +  90.0) / 180.0 * side))
    out = []
    for x in range(min_x, max_x + 1):
        for y in range(min_y, max_y + 1):
            cell_min_lon = -180.0 + x * lon_step
            cell_max_lon = -180.0 + (x + 1) * lon_step
            cell_min_lat =  -90.0 + y * lat_step
            cell_max_lat =  -90.0 + (y + 1) * lat_step
            out.append((cell_min_lon, cell_min_lat,
                        cell_max_lon, cell_max_lat))
    return out


def panel_cells_at_match(ax, side_km, qz_level, label_qz, label_gh):
    """Panel 2: show the cells qz_level / gh-2L would use to cover the
    side_km query. Both produce the same cells before merge -- difference
    is in WHICH groups get merged."""
    mn_lon, mn_lat, mx_lon, mx_lat = rect_bbox_deg(LAT, LON, side_km)
    cells = cells_at_level(mn_lon, mn_lat, mx_lon, mx_lat, qz_level)

    # Draw the cells (unmerged, at the leaf level)
    for c_mn_lon, c_mn_lat, c_mx_lon, c_mx_lat in cells:
        rect = patches.Rectangle(
            (c_mn_lon, c_mn_lat),
            c_mx_lon - c_mn_lon, c_mx_lat - c_mn_lat,
            linewidth=0.3, edgecolor="black", facecolor="lightblue",
            alpha=0.4)
        ax.add_patch(rect)

    # Draw the query rectangle on top
    rect = patches.Rectangle(
        (mn_lon, mn_lat), mx_lon - mn_lon, mx_lat - mn_lat,
        linewidth=2.0, edgecolor="red", facecolor="none",
        label=f"{side_km} km query")
    ax.add_patch(rect)

    # Mark the center
    ax.plot(LON, LAT, "k+", markersize=10, mew=2)

    margin = (mx_lon - mn_lon) * 0.4
    ax.set_xlim(mn_lon - margin, mx_lon + margin)
    ax.set_ylim(mn_lat - margin, mx_lat + margin)
    ax.set_aspect("equal", "box")
    ax.set_xlabel("longitude (°)")
    ax.set_ylabel("latitude (°)")
    ax.set_title(f"{side_km} km query at the same physical cells used by\n"
                 f"{label_qz} (4-ary) and {label_gh} (32-ary)\n"
                 f"({len(cells)} cells before merge -- merge counts shown "
                 f"in the qz_vs_gh table)")
    ax.legend(loc="upper right", fontsize=8)
    ax.grid(True, alpha=0.3)


def main():
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(15, 7))
    panel_workload(ax1)
    # Pick the side where qz vs gh diverge most clearly: 80 km, qz_L10/gh-4
    # (cells 0.352° x 0.176°) -- 26 vs 50 in the table.
    panel_cells_at_match(ax2, 80, 10, "qz_L10", "gh-4")

    fig.tight_layout()
    out_dir = sys.argv[1] if len(sys.argv) > 1 else \
        "results/run_20260506_191928"
    out_path = os.path.join(out_dir, "qz_vs_gh_workload.png")
    fig.savefig(out_path, dpi=130, bbox_inches="tight")
    print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
