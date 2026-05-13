"""
Sweep parameters used by latency_sweep.py and cell_count_sweep.py.

Two-tier layout:
  * LONGITUDES and SIDE_KM are SHARED — both scripts agree on which
    anchor longitudes to anti-alias against and how big the envelope is.
  * LATITUDES are PER-SCRIPT because the two have very different runtime
    budgets:
      - latency_sweep does EXPLAIN(ANALYZE, DIST) at every sample point
        with warmup + measured runs against a 344K-row table. Each lat
        ~= 30s of work; we keep the grid small (8 points).
      - cell_count_sweep just calls a covering function and counts the
        result array. Each lat is sub-second; we can afford dense pole
        sampling (24 points, every 5° below 80° + every 1° from 82-89°)
        which is exactly where the distortion shape gets interesting.

Change a value here and both scripts pick it up on their next run.
"""

# ---- shared across scripts ------------------------------------------------

# Anchor longitudes — split per-script because the two sweeps want different
# things from this axis:
#
# CELL_COUNT_LONGITUDES: 4 anchors used by cell_count_sweep.py for
#   ANTI-ALIASING. The covering algorithms are deterministic given the
#   envelope, but a single anchor can luck into a perfect cell-boundary
#   alignment and emit an unrealistically small cover. Sampling 4 lons
#   averages that out.
#
# LATENCY_LONGITUDES: 1 anchor used by latency_sweep.py for POPULATION
#   CONTROL. Real DBs have heterogeneous row density across longitudes —
#   a 50km envelope at lat=45/lon=10 (Italy) catches 9 cities, the same
#   envelope at lat=45/lon=120 catches 0. Sweeping over multiple
#   longitudes would mix two effects (latitude distortion + longitude
#   density). Fixing longitude leaves only the latitude effect, which
#   is what the distortion experiment is designed to measure.
#
# lon=15 chosen because it runs through dense European corridor (Italy
# → Austria → Germany → Sweden → Svalbard) and has cities at the most
# test latitudes — see the grid scan in commit / chat history.
CELL_COUNT_LONGITUDES = [7.0, 31.0, 55.0, 79.0]
LATENCY_LONGITUDES    = [15.0]

# Backward-compat alias (cell_count_sweep was importing LONGITUDES). After
# this commit, scripts should import LATENCY_LONGITUDES or CELL_COUNT_LONGITUDES
# explicitly. This alias points at the cell_count list (the wider one).
LONGITUDES = CELL_COUNT_LONGITUDES

# Envelope size: SIDE_KM × SIDE_KM real-area box. Both scripts construct
# a lat-lon envelope cos(lat)-corrected so the bounded area stays
# constant across latitudes — otherwise a fixed deg-by-deg box would
# shrink toward the pole and hide the distortion we want to measure.
SIDE_KM = 50


# ---- per-script latitude grids -------------------------------------------

# latency_sweep.py: 8 well-spread points. Each EXPLAIN ANALYZE costs
# ~seconds; we balance "enough to see the curve" against total run time.
# Lat 86 is the high-end point — past 86 the cell counts blow up so much
# that the DB-side recheck cost dominates and you stop measuring the
# index. Use cell_count_sweep for finer resolution near the pole.
LATENCY_LATITUDES = [0, 16, 31, 46, 52, 61, 71, 80]

# cell_count_sweep.py: 24 points. Every 5° up to 80°, then dense (1°)
# from 82 to 89 because that's where geohash cell counts go vertical.
# Pure geometry, no DB cost, so density is essentially free.
CELL_COUNT_LATITUDES = [
    0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80,
    82, 84, 85, 86, 87, 88, 89,
]
