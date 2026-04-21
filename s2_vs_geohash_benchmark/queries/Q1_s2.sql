-- Q1_s2.sql : 10 nearest POIs within 5 km of Fort Collins, CO
-- yb_geospatial_s2: spatial_candidates() (BETWEEN + ANY ancestor lookup)
-- followed by exact ST_DistanceSphere filter.
-- ----------------------------------------------------------------------------
-- 5 km at 40.5 lat is about 0.059 deg lon and 0.045 deg lat, so a padded
-- envelope of (-105.15,40.52)->(-105.00,40.65) comfortably covers the circle.
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT md_pk,
       md_name,
       md_city,
       ST_DistanceSphere(geom,
                         ST_GeomFromText('POINT(-105.0775 40.5853)', 4326)) AS dist_m
  FROM my_mapdata
 WHERE md_pk IN (
         SELECT spatial_candidates(
           'my_mapdata',
           ST_MakeEnvelope(-105.15, 40.52, -105.00, 40.65, 4326))
       )
   AND ST_DistanceSphere(geom,
                         ST_GeomFromText('POINT(-105.0775 40.5853)', 4326)) <= 5000
 ORDER BY dist_m
 LIMIT 10;
