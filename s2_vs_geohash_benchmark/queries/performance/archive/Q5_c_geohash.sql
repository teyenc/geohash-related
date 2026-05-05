-- Q5_c_geohash.sql : COUNT of POIs whose bbox overlaps the Front Range box,
--                    using the && operator.
-- ============================================================================
-- Mirror of Q5_s2.sql. The && operator on yb_geospatial_s2's `geometry`
-- type is itself a bbox-overlap predicate; we keep it for the recheck and
-- restrict candidates via cgeo_spatial_candidates.
-- ============================================================================

\timing on
EXPLAIN (ANALYZE, VERBOSE, FORMAT TEXT)
SELECT count(*)
  FROM my_mapdata
 WHERE md_pk IN (
         SELECT cgeo_spatial_candidates(
           'my_mapdata',
           ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326)))
   AND geom && ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326);
