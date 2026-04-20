-- Q1_s2.sql : 10 nearest POIs within 1 km of Fort Collins, CO
-- yb_geospatial_s2: spatial_candidates() (BETWEEN + ANY ancestor lookup)
-- followed by exact ST_DistanceSphere filter.
-- ----------------------------------------------------------------------------
-- 1 km at 40.5 lat is about 0.013 degrees lon and 0.009 degrees lat, so a
-- padded square of +/-0.015 deg is a safe BBox for the index filter.
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
           ST_MakeEnvelope(-105.0925, 40.5703, -105.0625, 40.6003, 4326))
       )
   AND ST_DistanceSphere(geom,
                         ST_GeomFromText('POINT(-105.0775 40.5853)', 4326)) <= 1000
 ORDER BY dist_m
 LIMIT 10;
