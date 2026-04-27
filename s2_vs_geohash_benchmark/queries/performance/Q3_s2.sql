-- Q3_s2.sql : COUNT of POIs inside a 2.5 deg x 2.0 deg (~200 km x ~200 km)
-- Colorado Front Range box.
-- ============================================================================
-- IDENTICAL SQL TO Q3_postgis.sql.
--
-- Our planner hook recognises the ST_Intersects(geom, polygon) predicate
-- and transparently injects
--
--    AND md_pk = ANY(SELECT spatial_candidates('my_mapdata', polygon))
--
-- so the standard planner does an Index Scan over my_mapdata_s2_index.
-- ============================================================================
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT count(*) AS hits
  FROM my_mapdata
 WHERE ST_Intersects(
         geom,
         ST_GeomFromText(
           'POLYGON((-106.20 38.80, -103.70 38.80, -103.70 40.80, -106.20 40.80, -106.20 38.80))',
           4326));
