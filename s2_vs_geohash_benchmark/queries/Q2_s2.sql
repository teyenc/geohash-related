-- Q2_s2.sql : COUNT of POIs within 50 km of Fort Collins, CO
-- ----------------------------------------------------------------------------
-- 50 km ~= 0.59 deg lon / 0.45 deg lat at 40.5 lat.  Padded envelope
-- (-105.68, 40.08) -> (-104.48, 41.08) covers the circle comfortably.
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT count(*) AS hits
  FROM my_mapdata
 WHERE md_pk IN (
         SELECT spatial_candidates(
           'my_mapdata',
           ST_MakeEnvelope(-105.68, 40.08, -104.48, 41.08, 4326))
       )
   AND ST_DistanceSphere(geom,
                         ST_GeomFromText('POINT(-105.0775 40.5853)', 4326)) <= 50000;
