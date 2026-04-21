-- Q4_s2.sql : rivers that intersect the western-US envelope (~5x CA area)
-- spatial_candidates() returns rivers whose S2 covering touches the bbox cells;
-- ST_Intersects() is the exact recheck done in GEOS.
-- ----------------------------------------------------------------------------
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT count(*) AS rivers_in_west_us
  FROM rivers
 WHERE id IN (
         SELECT spatial_candidates(
           'rivers',
           ST_MakeEnvelope(-125.0, 30.0, -100.0, 50.0, 4326))
       )
   AND ST_Intersects(
         geom,
         ST_MakeEnvelope(-125.0, 30.0, -100.0, 50.0, 4326));
