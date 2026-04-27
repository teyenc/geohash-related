-- Q2_s2.sql : COUNT of POIs within 50 km of Fort Collins, CO
-- ============================================================================
-- IDENTICAL SQL TO Q2_postgis.sql.
--
-- Our planner hook recognises ST_DWithin(geography, geography, distance,
-- use_spheroid), computes a padded envelope from the inlined point + radius,
-- and injects
--    AND md_pk = ANY(SELECT spatial_candidates('my_mapdata', envelope))
-- so the standard YB planner does an Index Scan over my_mapdata_s2_index.
-- The exact recheck (ST_DWithin on geography) delegates to ST_DistanceSpheroid
-- (Karney geodesic) -- row-identical to PostGIS's Vincenty.
-- ============================================================================
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT count(*) AS hits
  FROM my_mapdata
 WHERE ST_DWithin(geom::geography,
                  ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography,
                  50000, true);
