-- Q1_c_geohash.sql : 10 nearest POIs within 5 km of Fort Collins, CO
-- ============================================================================
-- IDENTICAL SHAPE TO Q1_s2.sql, but without the planner hook (c_geohash
-- doesn't have one). The candidate-cell injection is therefore done
-- EXPLICITLY in SQL via cgeo_spatial_candidates(table, query_geom).
--
-- IMPORTANT — query SHAPE matters:
--   We use `md_pk IN (SELECT cgeo_spatial_candidates(...))` (NOT
--   `= ANY(ARRAY(SELECT ...))`). The ARRAY() wrapper would materialize the
--   candidate set into a constant int8[] before the join, forcing a
--   `md_pk = ANY($1)` array-probe plan — that's a SubPlan + Hashed-IN,
--   not a join, so YB BNL cannot fire. With `IN (SELECT ...)` the planner
--   keeps the semijoin shape, so the YB Batched Nested Loop Join kicks in
--   and ships ~1000 candidate md_pk's per DocDB RPC round-trip.
--
-- UNDER THE HOOD (c_geohash):
--   * c_geohash_cover_geometry(envelope, 4, 10) returns the bbox cover as
--     int8 cells via the merged 32-child algorithm.
--   * cgeo_spatial_candidates fans out the cover into two B-tree probes
--     per cell: BETWEEN [range_min, range_max] for descendants, = ANY(...)
--     for ancestors. Mirror of yb_geospatial_s2's spatial_candidates.
--   * The ST_DWithin filter remains for exact recheck (Vincenty geodesic
--     via the yb_geospatial_s2 GEOS path).
-- ============================================================================
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT md_pk,
       md_name,
       md_city,
       ST_Distance(geom::geography,
                   ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography,
                   true) AS dist_m
  FROM my_mapdata
 WHERE md_pk IN (
         SELECT cgeo_spatial_candidates(
           'my_mapdata',
           -- Pad the point by ~5 km in lon/lat degrees (cosine-aware on
           -- lon for lat 40.5; same heuristic the S2 planner hook uses).
           ST_MakeEnvelope(-105.0775 - 0.0590, 40.5853 - 0.0450,
                           -105.0775 + 0.0590, 40.5853 + 0.0450, 4326)))
   AND ST_DWithin(geom::geography,
                  ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography,
                  5000, true)
 ORDER BY dist_m
 LIMIT 10;
