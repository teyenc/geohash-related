-- Q2_s2.sql : COUNT of POIs within 10 km of Fort Collins, CO
-- ----------------------------------------------------------------------------
-- 10 km ~= 0.13 deg lon / 0.09 deg lat at 40.5 lat.  Use +/-0.12 deg envelope.
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT count(*) AS hits
  FROM my_mapdata
 WHERE md_pk IN (
         SELECT spatial_candidates(
           'my_mapdata',
           ST_MakeEnvelope(-105.20, 40.47, -104.95, 40.70, 4326))
       )
   AND ST_DistanceSphere(geom,
                         ST_GeomFromText('POINT(-105.0775 40.5853)', 4326)) <= 10000;
