-- Q4_s2.sql : rivers that intersect the California envelope
-- spatial_candidates() returns rivers whose S2 covering touches the CA cells;
-- ST_Intersects() is the exact recheck done in GEOS.
-- ----------------------------------------------------------------------------
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT count(*) AS rivers_in_ca
  FROM rivers
 WHERE id IN (
         SELECT spatial_candidates(
           'rivers',
           ST_MakeEnvelope(-124.4, 32.5, -114.1, 42.0, 4326))
       )
   AND ST_Intersects(
         geom,
         ST_MakeEnvelope(-124.4, 32.5, -114.1, 42.0, 4326));
