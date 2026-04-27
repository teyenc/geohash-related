-- Q1_s2.sql : 10 nearest POIs within 5 km of Fort Collins, CO
-- ============================================================================
-- IDENTICAL SQL TO Q1_postgis.sql.
--
-- The point is inlined (no CTE) so the planner hook can produce a clean
-- Index Scan plan on bench_s2.  YB cannot push a hashed-SubPlan reference
-- down into Index Scan, which is what a CTE-bound point would generate.
--
-- UNDER THE HOOD (S2):
--   * Our planner hook (yb_geo_planner_hook.c) recognises the
--     ST_DWithin(geography, geography, distance, use_spheroid) call,
--     extracts the inline point and the 5000 m radius, and computes
--     envelope = ST_Expand(point, dist/30000).
--   * It then injects a SubLink filter
--         AND md_pk = ANY(SELECT spatial_candidates('my_mapdata', envelope))
--     so the standard planner does an Index Scan over my_mapdata_s2_index.
--   * The original ST_DWithin remains as the Filter for exact recheck;
--     it delegates to ST_DistanceSpheroid (Karney geodesic via the
--     vendored PROJ geodesic routines) so the answer is row-identical
--     to PostGIS's Vincenty.
-- ============================================================================
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT md_pk,
       md_name,
       md_city,
       ST_Distance(geom::geography,
                   ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography,
                   true) AS dist_m
  FROM my_mapdata
 WHERE ST_DWithin(geom::geography,
                  ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography,
                  5000, true)
 ORDER BY dist_m
 LIMIT 10;
