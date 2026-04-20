#!/usr/bin/env python3
# ==============================================================================
# gen_rivers.py
#
# Generates 5,000 synthetic "rivers" (polylines) distributed across the
# continental US.  Each river is a random walk of 15 segments, ~5 km each,
# starting from a random location between (lon -125..-66, lat 24..49).
#
# Emits a CSV to stdout with columns:
#    id (int), name (text), wkt (text), lon_array (text), lat_array (text)
#
# The same seed is used every run so all three engines (PostGIS, S2, Dan's)
# load an identical dataset.
# ==============================================================================
import random
import sys

random.seed(42)

N_RIVERS    = 5000
VERTICES    = 15
STEP_DEG    = 0.05   # ~5 km at mid-latitudes

print("id|name|wkt|lon_array|lat_array")

for i in range(1, N_RIVERS + 1):
    # Uniform starting point inside the US continental bbox
    lon0 = -125.0 + random.random() * 59.0
    lat0 =   24.0 + random.random() * 25.0

    lons = [lon0]
    lats = [lat0]
    for _ in range(1, VERTICES):
        lons.append(lons[-1] + (random.random() - 0.5) * 2 * STEP_DEG)
        lats.append(lats[-1] + (random.random() - 0.5) * 2 * STEP_DEG)

    wkt = "LINESTRING(" + ",".join(f"{x:.6f} {y:.6f}" for x, y in zip(lons, lats)) + ")"

    # PostgreSQL array literal, e.g. "{-120.1,-120.15,-120.2}"
    lon_arr = "{" + ",".join(f"{x:.6f}" for x in lons) + "}"
    lat_arr = "{" + ",".join(f"{y:.6f}" for y in lats) + "}"

    print(f"{i}|river_{i}|{wkt}|{lon_arr}|{lat_arr}")
