"""
SQL the latency_sweep sends to each engine's DB.

Everything related to "what queries does the benchmark execute" lives here:
  * per-engine cover-level parameters (GH_PURE_PREC, GH_ADAPT_MAX, etc.)
  * envelope-construction helpers (cos(lat)-corrected real-area box)
  * per-engine query builders (query_pure_sql / query_c_geohash / query_qz /
    query_s2) — each returns the exact SQL the sweep sends
  * QUERY_BUILDERS dict, indexed by engine name

To inspect any query for a given (lat, lon) without running anything:

    python3 -c "import sweep_queries as Q; print(Q.query_s2(86, 55.0))"

----------------------------------------------------------------------------
Query shape
----------------------------------------------------------------------------
All four queries share the same skeleton:

    EXPLAIN (ANALYZE, DIST, COSTS OFF, SUMMARY ON, FORMAT TEXT)
    SELECT count(*) FROM my_mapdata
     WHERE md_pk IN (<engine-specific cell-candidates helper>)
       AND ST_X(geom) BETWEEN xmin AND xmax     -- recheck via raw lat/lon
       AND ST_Y(geom) BETWEEN ymin AND ymax;    --   (NOT ST_Intersects, so
                                                --    the yb_geospatial_s2
                                                --    planner hook never fires)

  * `md_pk IN (SELECT setof_int8_func(...))` is a SQL **semi-join**: keep
    rows from my_mapdata whose PK matches *any* value returned by the
    cell-candidates helper. The helper returns SETOF int8 (one row per
    candidate md_pk).
  * The ST_X/ST_Y bbox compare is the **recheck** — without it the helper
    could over-report (cells that touch the envelope's bbox aren't all
    contained by the envelope itself). Using lat/lon BETWEEN instead of
    ST_Intersects keeps the yb_geospatial_s2 planner hook out of the
    picture, so we measure the engine we asked for, not the hook's rewrite.

----------------------------------------------------------------------------
What the plan looks like (real EXPLAIN ANALYZE output)
----------------------------------------------------------------------------
Both c_geohash and s2 produce the same plan shape — only the candidates
helper differs. Example below from run_20260513_064034 at lat=0/lon=7
(Gulf of Guinea, no POIs, so the inner index lookup is `(never executed)`):

  Aggregate                                    -- SELECT count(*)
    -> YB Batched Nested Loop Join             -- BNLJ: batches up to 1024
         Join Filter: md_pk = (<helper>(...))  --   candidates per inner scan
         -> HashAggregate                       -- dedupe candidates
              Group Key: <helper>(...)
              -> ProjectSet                     -- expand SETOF int8
                   -> Result *RESULT*           -- the helper function call
                        Storage Table Read     -- <— THIS is the cell-cover
                          Requests: 4100       --     RPC count we plot.
                          Time: 802 ms         --     One RPC per BETWEEN
                                               --     range scan on the
                                               --     engine's mapping table.
         -> Index Scan using my_mapdata_pkey   -- BNLJ inner side; one RPC
              (never executed)                 --   per batch of 1024
              Index Cond: md_pk = ANY (        --     candidates. "never
                ARRAY[..., $1..$1023])         --     executed" here because
              Filter: ST_X(geom) BETWEEN ...   --     0 candidates returned.
                  AND ST_Y(geom) BETWEEN ...
  Planning Time: 0.5 ms
  Execution Time: 1053 ms
  Storage Read Requests: 4100                  -- plan-total RPCs; the
                                               -- script parses this line
                                               -- into the CSV's
                                               -- `storage_reads` column.

Most of the wall time and *all* of the RPCs come from the candidates
function itself — the BNLJ inner-scan path adds at most ~ceil(N/1024)
extra RPCs, which is invisible against the per-cell range-scan cost.
That's exactly the property we want for a distortion benchmark: what
we measure IS what the cover function costs to materialize.
----------------------------------------------------------------------------
"""
import math

from sweep_config import SIDE_KM

# ---- table/column constants (same across all engines) ---------------------

SOURCE_TABLE = 'my_mapdata'
PK_COLUMN    = 'md_pk'
GH_COLUMN    = 'geo_hash10'

# ---- query shape ----------------------------------------------------------
#
# Two recheck shapes supported (selected by the harness via QUERY_BUILDERS
# vs CIRCLE_QUERY_BUILDERS — see latency_sweep.py's --shape flag):
#
#   box     : recheck via ST_X/ST_Y lat/lon BETWEEN. Cheap arithmetic, no
#             GEOS calls. Same as the original distortion sweep.
#   circle  : recheck via ST_DistanceSphere(geom, center) <= radius_m.
#             GEOS-backed sphere distance, meters. Inscribed circle in the
#             SIDE_KM × SIDE_KM envelope (so RADIUS_KM = SIDE_KM / 2).
#
# Both shapes share the SAME envelope for the cell-cover pre-filter — only
# the recheck differs. That makes the comparison apples-to-apples on cover
# cost (RPCs); any wall-time delta is the recheck-per-row cost (GEOS call
# vs two BETWEEN tests).
#
# Why ST_DistanceSphere, not ST_DWithin: yb_geospatial_s2's planner hook
# intercepts ST_DWithin and rewrites it to call spatial_candidates auto-
# matically. We already pass spatial_candidates_v2 explicitly with our own
# min/max levels and max_cells; we don't want a second hook-rewrite. A
# raw distance function returning float8 isn't a predicate the hook can
# pattern-match, so it stays out of the way.

RADIUS_KM = 50     # circle radius in km; matches half of SIDE_KM (50)
                   # so the circle is inscribed in the same envelope as
                   # the box query — identical cell-cover work, only the
                   # set of "kept" rows differs (the circle is smaller).

# ---- per-engine cover parameters ------------------------------------------

# pure_sql: fixed-precision LEFT(geo_hash10, N) bucket lookup.
GH_PURE_PREC   = 6

# c_geohash adaptive cover: 32-ary Z-order, min..max precision range.
GH_ADAPT_MIN   = 2     # ~11°×5.6° coarse cells
GH_ADAPT_MAX   = 7     # ~152m × 152m leaf cells at the equator

# c_quadtree_z adaptive cover: 4-ary Z-order. QZ adaptive min is fixed at 5
# inside qz_text_spatial_candidates (matches gh's GH_ADAPT_MIN=2 in coarse
# cell area); only the max level is parameterized here.
QZ_ADAPT_MAX   = 18    # ~153m × 76m leaf cells at the equator
                       # (cell area ~11.7k m², smaller than S2-16's ~20.2k m²,
                       # which flips the cell-size confound so any qz / s2
                       # advantage in cluster count is purely the curve effect)

# S2 adaptive cover: 4-ary Hilbert, min..max level range.
S2_ADAPT_MIN   = 10
S2_ADAPT_MAX   = 16    # leaf edge ~142m globally
S2_MAX_CELLS   = 1_000_000   # effectively unbounded — let S2 emit as many
                             # adaptive cells as it needs within [min, max]


# ---- envelope helpers -----------------------------------------------------

def envelope_coords(lat, lon, side_km=SIDE_KM):
    """Fixed-area side_km × side_km envelope centered at (lat, lon).
    Lon span scales with cos(lat) to keep the bounded area constant across
    latitudes — otherwise a fixed deg-by-deg box would shrink toward the
    pole and hide the distortion we want to measure.
    """
    half_lat_deg = (side_km / 2) / 111.0
    cos_lat = max(math.cos(math.radians(lat)), 0.001)
    half_lon_deg = (side_km / 2) / (111.0 * cos_lat)
    return (lon - half_lon_deg, lat - half_lat_deg,
            lon + half_lon_deg, lat + half_lat_deg)


def envelope_st_makeenvelope(xmin, ymin, xmax, ymax):
    return f"ST_MakeEnvelope({xmin}, {ymin}, {xmax}, {ymax}, 4326)"


# ---- per-engine query builders --------------------------------------------

def query_pure_sql(lat, lon):
    """Dan's pure-SQL geohash. Recheck via ST_X/ST_Y bbox compare (called
    only on the small candidate set after the LEFT(...) pre-filter narrows
    it down). No ST_Intersects -> no planner hook.

    Plan signature (slightly different from the other three — no semi-join,
    just an expression-indexable column predicate):
       Aggregate
         -> Index Scan using my_mapdata_left_gh6_idx on my_mapdata
              Index Cond: LEFT(geo_hash10, 6) = ANY ({...cells...})
              Filter: ST_X/ST_Y BETWEEN ...
    """
    xmin, ymin, xmax, ymax = envelope_coords(lat, lon)
    return f"""EXPLAIN (ANALYZE, DIST, COSTS OFF, SUMMARY ON, FORMAT TEXT)
SELECT count(*) FROM {SOURCE_TABLE}
 WHERE LEFT({GH_COLUMN}, {GH_PURE_PREC}) = ANY(
         ARRAY(SELECT * FROM geohash_cells_for_bbox(
                 {xmin}, {ymin}, {xmax}, {ymax}, {GH_PURE_PREC})))
   AND ST_X(geom) BETWEEN {xmin} AND {xmax}
   AND ST_Y(geom) BETWEEN {ymin} AND {ymax};
"""


def query_c_geohash(lat, lon):
    """c_geohash adaptive cover via cgeo_text_spatial_candidates (32-ary
    tree, Z-order curve). Helper internally calls c_geohash_cover_geometry,
    then BETWEEN-scans my_mapdata_cgeo_index for each (min10, max10) pair.

    Plan signature — standard semi-join shape (see module-level comment):
       Aggregate
         -> YB Batched Nested Loop Join
              -> HashAggregate
                   -> ProjectSet
                        -> Result *RESULT*  [cgeo_text_spatial_candidates]
                             Storage Table Read Requests: <gh RPC count>
              -> Index Scan using my_mapdata_pkey
                   Index Cond: md_pk = ANY (ARRAY[..., $1..$1023])
                   Filter: ST_X/ST_Y BETWEEN ...
    """
    xmin, ymin, xmax, ymax = envelope_coords(lat, lon)
    env = envelope_st_makeenvelope(xmin, ymin, xmax, ymax)
    return f"""EXPLAIN (ANALYZE, DIST, COSTS OFF, SUMMARY ON, FORMAT TEXT)
SELECT count(*) FROM {SOURCE_TABLE}
 WHERE {PK_COLUMN} IN (
         SELECT cgeo_text_spatial_candidates('{SOURCE_TABLE}', {env}, {GH_ADAPT_MAX}))
   AND ST_X(geom) BETWEEN {xmin} AND {xmax}
   AND ST_Y(geom) BETWEEN {ymin} AND {ymax};
"""


def query_qz(lat, lon):
    """c_quadtree_z adaptive cover via qz_text_spatial_candidates (4-ary
    tree, Z-order curve — the c_geohash branching-factor control).
    Installed in bench_qz by 05_setup_yb_qz.sh.

    Plan signature — identical to query_c_geohash, only the helper name
    differs (qz_text_spatial_candidates) and the BETWEEN-scan target is
    my_mapdata_qz_index instead of my_mapdata_cgeo_index.
    """
    xmin, ymin, xmax, ymax = envelope_coords(lat, lon)
    env = envelope_st_makeenvelope(xmin, ymin, xmax, ymax)
    return f"""EXPLAIN (ANALYZE, DIST, COSTS OFF, SUMMARY ON, FORMAT TEXT)
SELECT count(*) FROM {SOURCE_TABLE}
 WHERE {PK_COLUMN} IN (
         SELECT qz_text_spatial_candidates('{SOURCE_TABLE}', {env}, {QZ_ADAPT_MAX}))
   AND ST_X(geom) BETWEEN {xmin} AND {xmax}
   AND ST_Y(geom) BETWEEN {ymin} AND {ymax};
"""


def query_s2(lat, lon):
    """S2 adaptive cover (descendants + ancestors) via spatial_candidates_v2
    (4-ary tree, Hilbert curve). Helper internally calls ST_S2Covering, then
    range-scans my_mapdata_s2_index for descendants and ARRAY-matches it
    for ancestors of each emitted s2 cell.

    Plan signature — identical to query_c_geohash, only the helper name
    differs (spatial_candidates_v2 with explicit min_level/max_level/
    max_cells args) and the BETWEEN-scan target is my_mapdata_s2_index.
    Real example RPC count: lat=0/lon=7, 50km envelope -> ~3920 RPCs.
    """
    xmin, ymin, xmax, ymax = envelope_coords(lat, lon)
    env = envelope_st_makeenvelope(xmin, ymin, xmax, ymax)
    return f"""EXPLAIN (ANALYZE, DIST, COSTS OFF, SUMMARY ON, FORMAT TEXT)
SELECT count(*) FROM {SOURCE_TABLE}
 WHERE {PK_COLUMN} IN (
         SELECT spatial_candidates_v2('{SOURCE_TABLE}', {env},
                                      {S2_ADAPT_MIN}, {S2_ADAPT_MAX},
                                      {S2_MAX_CELLS}))
   AND ST_X(geom) BETWEEN {xmin} AND {xmax}
   AND ST_Y(geom) BETWEEN {ymin} AND {ymax};
"""


QUERY_BUILDERS = {
    'pure_sql':  query_pure_sql,
    'c_geohash': query_c_geohash,
    'qz':        query_qz,
    's2':        query_s2,
}


# ---------------------------------------------------------------------------
# Circle-shape variants
# ---------------------------------------------------------------------------
# Same cell-cover pre-filter as the box queries above (the cell-candidates
# helpers still take the SIDE_KM × SIDE_KM envelope as input — no point
# making the cover function compute against a curved polygon).
#
# The recheck is what changes:
#     ST_DistanceSphere(geom, center) <= RADIUS_KM * 1000
# where `center` is the (lon, lat) point. This filters down to the
# inscribed circle inside the envelope.

def _center_point_sql(lat, lon):
    """SQL fragment for the circle center point as a SRID=4326 geometry."""
    return f"ST_SetSRID(ST_MakePoint({lon}, {lat}), 4326)"


def query_circle_pure_sql(lat, lon):
    """pure_sql circle variant. Recheck uses a planar approximation —
    Dan's bench_dans doesn't have ST_DistanceSphere on Dan's custom
    geometry type. cos(lat)-corrected meters^2 comparison, fine for
    small (50 km-scale) envelopes."""
    xmin, ymin, xmax, ymax = envelope_coords(lat, lon)
    radius_m_sq = (RADIUS_KM * 1000.0) ** 2
    cos_lat = max(math.cos(math.radians(lat)), 0.001)
    # Distance² in meters², via planar approximation. Avoids dependence on
    # PostGIS-style distance functions in bench_dans.
    return f"""EXPLAIN (ANALYZE, DIST, COSTS OFF, SUMMARY ON, FORMAT TEXT)
SELECT count(*) FROM {SOURCE_TABLE}
 WHERE LEFT({GH_COLUMN}, {GH_PURE_PREC}) = ANY(
         ARRAY(SELECT * FROM geohash_cells_for_bbox(
                 {xmin}, {ymin}, {xmax}, {ymax}, {GH_PURE_PREC})))
   AND (
         ((ST_X(geom) - {lon}) * 111000.0 * {cos_lat}) * ((ST_X(geom) - {lon}) * 111000.0 * {cos_lat})
       + ((ST_Y(geom) - {lat}) * 111000.0)            * ((ST_Y(geom) - {lat}) * 111000.0)
       ) <= {radius_m_sq};
"""


def query_circle_c_geohash(lat, lon):
    """c_geohash circle variant. Same cover pre-filter as the box query;
    recheck is ST_DistanceSphere (GEOS-backed sphere distance, meters)."""
    xmin, ymin, xmax, ymax = envelope_coords(lat, lon)
    env = envelope_st_makeenvelope(xmin, ymin, xmax, ymax)
    radius_m = RADIUS_KM * 1000
    return f"""EXPLAIN (ANALYZE, DIST, COSTS OFF, SUMMARY ON, FORMAT TEXT)
SELECT count(*) FROM {SOURCE_TABLE}
 WHERE {PK_COLUMN} IN (
         SELECT cgeo_text_spatial_candidates('{SOURCE_TABLE}', {env}, {GH_ADAPT_MAX}))
   AND ST_DistanceSphere(geom, {_center_point_sql(lat, lon)}) <= {radius_m};
"""


def query_circle_qz(lat, lon):
    """qz circle variant. Same shape as query_circle_c_geohash with the
    qz_text_spatial_candidates helper instead."""
    xmin, ymin, xmax, ymax = envelope_coords(lat, lon)
    env = envelope_st_makeenvelope(xmin, ymin, xmax, ymax)
    radius_m = RADIUS_KM * 1000
    return f"""EXPLAIN (ANALYZE, DIST, COSTS OFF, SUMMARY ON, FORMAT TEXT)
SELECT count(*) FROM {SOURCE_TABLE}
 WHERE {PK_COLUMN} IN (
         SELECT qz_text_spatial_candidates('{SOURCE_TABLE}', {env}, {QZ_ADAPT_MAX}))
   AND ST_DistanceSphere(geom, {_center_point_sql(lat, lon)}) <= {radius_m};
"""


def query_circle_s2(lat, lon):
    """s2 circle variant. Note we deliberately use ST_DistanceSphere, NOT
    ST_DWithin — the yb_geospatial_s2 planner hook would rewrite ST_DWithin
    to call spatial_candidates internally, conflicting with our explicit
    spatial_candidates_v2 invocation. ST_DistanceSphere is a distance
    function (returns float8), not a predicate the hook pattern-matches,
    so it stays out of the way."""
    xmin, ymin, xmax, ymax = envelope_coords(lat, lon)
    env = envelope_st_makeenvelope(xmin, ymin, xmax, ymax)
    radius_m = RADIUS_KM * 1000
    return f"""EXPLAIN (ANALYZE, DIST, COSTS OFF, SUMMARY ON, FORMAT TEXT)
SELECT count(*) FROM {SOURCE_TABLE}
 WHERE {PK_COLUMN} IN (
         SELECT spatial_candidates_v2('{SOURCE_TABLE}', {env},
                                      {S2_ADAPT_MIN}, {S2_ADAPT_MAX},
                                      {S2_MAX_CELLS}))
   AND ST_DistanceSphere(geom, {_center_point_sql(lat, lon)}) <= {radius_m};
"""


CIRCLE_QUERY_BUILDERS = {
    'pure_sql':  query_circle_pure_sql,
    'c_geohash': query_circle_c_geohash,
    'qz':        query_circle_qz,
    's2':        query_circle_s2,
}


def builders_for_shape(shape):
    """Pick the right per-engine query-builder dict for the requested shape.
    'box' (default) -> ST_X/ST_Y BETWEEN recheck.
    'circle'        -> ST_DistanceSphere recheck (radius = RADIUS_KM)."""
    if shape == 'box':
        return QUERY_BUILDERS
    if shape == 'circle':
        return CIRCLE_QUERY_BUILDERS
    raise ValueError(f"unknown shape {shape!r} (expected 'box' or 'circle')")


# ============================================================================
# Ready-to-run examples
# ============================================================================
# All 8 query variants below are the *exact* SQL the sweep sends, with
# (lat=0, lon=7) substituted (a 50 km × 50 km envelope in the Gulf of
# Guinea; off the African coast, no POIs there — useful because plans
# stay simple and you can see the cell-cover cost in isolation).
#
# Pick a populated (lat, lon) like (31, 31) for "over Egypt" if you want
# rows actually returned. The math: envelope half-width in degrees is
#   half_lat = 25 / 111
#   half_lon = 25 / (111 * cos(radians(lat)))
# and the four envelope coords are (lon - half_lon, lat - half_lat,
# lon + half_lon, lat + half_lat). Or just call the builder:
#
#   python3 -c "from sweep_queries import query_c_geohash; print(query_c_geohash(31, 31))"
#
# ----------------------------------------------------------------------------
# How to open each DB
# ----------------------------------------------------------------------------
# YB benches (port 5433):
#   YSQL=/net/dev-server-te-yenchou/share/code/yugabyte-db/build/latest/postgres/bin/ysqlsh
#   $YSQL -h 127.0.0.1 -p 5433 -U yugabyte -d bench_dans       # pure_sql
#   $YSQL -h 127.0.0.1 -p 5433 -U yugabyte -d bench_cgeo       # c_geohash
#   $YSQL -h 127.0.0.1 -p 5433 -U yugabyte -d bench_qz         # qz
#   $YSQL -h 127.0.0.1 -p 5433 -U yugabyte -d bench_s2         # s2
#
# ----------------------------------------------------------------------------
# pure_sql (bench_dans) — box
# ----------------------------------------------------------------------------
# EXPLAIN (ANALYZE, DIST, COSTS OFF, SUMMARY ON, FORMAT TEXT)
# SELECT count(*) FROM my_mapdata
#  WHERE LEFT(geo_hash10, 6) = ANY(
#          ARRAY(SELECT * FROM geohash_cells_for_bbox(
#                  6.774774774774775, -0.22522522522522523,
#                  7.225225225225225,  0.22522522522522523, 6)))
#    AND ST_X(geom) BETWEEN 6.774774774774775 AND 7.225225225225225
#    AND ST_Y(geom) BETWEEN -0.22522522522522523 AND 0.22522522522522523;
#
# ----------------------------------------------------------------------------
# pure_sql (bench_dans) — circle
# ----------------------------------------------------------------------------
# (Recheck is planar approximation — Dan's geometry type doesn't have
#  ST_DistanceSphere. cos(lat)-corrected meters², 25 km radius squared.)
# EXPLAIN (ANALYZE, DIST, COSTS OFF, SUMMARY ON, FORMAT TEXT)
# SELECT count(*) FROM my_mapdata
#  WHERE LEFT(geo_hash10, 6) = ANY(
#          ARRAY(SELECT * FROM geohash_cells_for_bbox(
#                  6.774774774774775, -0.22522522522522523,
#                  7.225225225225225,  0.22522522522522523, 6)))
#    AND (
#          ((ST_X(geom) - 7.0) * 111000.0 * 1.0) * ((ST_X(geom) - 7.0) * 111000.0 * 1.0)
#        + ((ST_Y(geom) - 0)   * 111000.0)       * ((ST_Y(geom) - 0)   * 111000.0)
#        ) <= 625000000.0;     -- 25000² m²
#
# ----------------------------------------------------------------------------
# c_geohash (bench_cgeo) — box
# ----------------------------------------------------------------------------
# EXPLAIN (ANALYZE, DIST, COSTS OFF, SUMMARY ON, FORMAT TEXT)
# SELECT count(*) FROM my_mapdata
#  WHERE md_pk IN (
#          SELECT cgeo_text_spatial_candidates('my_mapdata',
#            ST_MakeEnvelope(6.774774774774775, -0.22522522522522523,
#                            7.225225225225225,  0.22522522522522523, 4326), 7))
#    AND ST_X(geom) BETWEEN 6.774774774774775 AND 7.225225225225225
#    AND ST_Y(geom) BETWEEN -0.22522522522522523 AND 0.22522522522522523;
#
# ----------------------------------------------------------------------------
# c_geohash (bench_cgeo) — circle
# ----------------------------------------------------------------------------
# EXPLAIN (ANALYZE, DIST, COSTS OFF, SUMMARY ON, FORMAT TEXT)
# SELECT count(*) FROM my_mapdata
#  WHERE md_pk IN (
#          SELECT cgeo_text_spatial_candidates('my_mapdata',
#            ST_MakeEnvelope(6.774774774774775, -0.22522522522522523,
#                            7.225225225225225,  0.22522522522522523, 4326), 7))
#    AND ST_DistanceSphere(geom,
#          ST_SetSRID(ST_MakePoint(7.0, 0), 4326)) <= 25000;
#
# ----------------------------------------------------------------------------
# qz (bench_qz) — box
# ----------------------------------------------------------------------------
# EXPLAIN (ANALYZE, DIST, COSTS OFF, SUMMARY ON, FORMAT TEXT)
# SELECT count(*) FROM my_mapdata
#  WHERE md_pk IN (
#          SELECT qz_text_spatial_candidates('my_mapdata',
#            ST_MakeEnvelope(6.774774774774775, -0.22522522522522523,
#                            7.225225225225225,  0.22522522522522523, 4326), 18))
#    AND ST_X(geom) BETWEEN 6.774774774774775 AND 7.225225225225225
#    AND ST_Y(geom) BETWEEN -0.22522522522522523 AND 0.22522522522522523;
#
# ----------------------------------------------------------------------------
# qz (bench_qz) — circle
# ----------------------------------------------------------------------------
# EXPLAIN (ANALYZE, DIST, COSTS OFF, SUMMARY ON, FORMAT TEXT)
# SELECT count(*) FROM my_mapdata
#  WHERE md_pk IN (
#          SELECT qz_text_spatial_candidates('my_mapdata',
#            ST_MakeEnvelope(6.774774774774775, -0.22522522522522523,
#                            7.225225225225225,  0.22522522522522523, 4326), 18))
#    AND ST_DistanceSphere(geom,
#          ST_SetSRID(ST_MakePoint(7.0, 0), 4326)) <= 25000;
#
# ----------------------------------------------------------------------------
# s2 (bench_s2) — box
# ----------------------------------------------------------------------------
# EXPLAIN (ANALYZE, DIST, COSTS OFF, SUMMARY ON, FORMAT TEXT)
# SELECT count(*) FROM my_mapdata
#  WHERE md_pk IN (
#          SELECT spatial_candidates_v2('my_mapdata',
#            ST_MakeEnvelope(6.774774774774775, -0.22522522522522523,
#                            7.225225225225225,  0.22522522522522523, 4326),
#            10, 16, 1000000))
#    AND ST_X(geom) BETWEEN 6.774774774774775 AND 7.225225225225225
#    AND ST_Y(geom) BETWEEN -0.22522522522522523 AND 0.22522522522522523;
#
# ----------------------------------------------------------------------------
# s2 (bench_s2) — circle
# ----------------------------------------------------------------------------
# (Note: ST_DistanceSphere, NOT ST_DWithin — the s2 planner hook would
#  rewrite ST_DWithin and conflict with our explicit spatial_candidates_v2.)
# EXPLAIN (ANALYZE, DIST, COSTS OFF, SUMMARY ON, FORMAT TEXT)
# SELECT count(*) FROM my_mapdata
#  WHERE md_pk IN (
#          SELECT spatial_candidates_v2('my_mapdata',
#            ST_MakeEnvelope(6.774774774774775, -0.22522522522522523,
#                            7.225225225225225,  0.22522522522522523, 4326),
#            10, 16, 1000000))
#    AND ST_DistanceSphere(geom,
#          ST_SetSRID(ST_MakePoint(7.0, 0), 4326)) <= 25000;
