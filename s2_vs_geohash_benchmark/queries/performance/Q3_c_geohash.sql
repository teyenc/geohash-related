-- Q3_c_geohash.sql : COUNT of POIs in the ~200 km Colorado Front Range box.
-- ============================================================================
-- Same shape as Q3_s2.sql; explicit cgeo_spatial_candidates injection.
-- Polygon recheck via ST_Intersects (GEOS).
-- ============================================================================
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT count(*) AS hits
  FROM my_mapdata
 WHERE md_pk IN (
         SELECT cgeo_spatial_candidates(
           'my_mapdata',
           ST_GeomFromText(
             'POLYGON((-106.20 38.80, -103.70 38.80, -103.70 40.80, '
             '-106.20 40.80, -106.20 38.80))', 4326)))
   AND ST_Intersects(
         geom,
         ST_GeomFromText(
           'POLYGON((-106.20 38.80, -103.70 38.80, -103.70 40.80, '
           '-106.20 40.80, -106.20 38.80))', 4326));
