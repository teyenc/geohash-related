-- Q3_s2.sql : COUNT of POIs inside Denver metro rectangle
-- ----------------------------------------------------------------------------
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT count(*) AS hits
  FROM my_mapdata
 WHERE md_pk IN (
         SELECT spatial_candidates(
           'my_mapdata',
           ST_MakeEnvelope(-105.20, 39.60, -104.70, 40.00, 4326))
       )
   AND ST_Intersects(
         geom,
         ST_MakeEnvelope(-105.20, 39.60, -104.70, 40.00, 4326));
