-- Q3_s2.sql : COUNT of POIs inside a 2.5 deg x 2.0 deg (~200 km x ~200 km)
-- Colorado Front Range box.
-- ----------------------------------------------------------------------------
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT count(*) AS hits
  FROM my_mapdata
 WHERE md_pk IN (
         SELECT spatial_candidates(
           'my_mapdata',
           ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326))
       )
   AND ST_Intersects(
         geom,
         ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326));
