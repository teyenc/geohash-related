-- Q3_postgis.sql : COUNT of POIs inside a polygon covering the Denver metro
-- ----------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT TEXT)
SELECT count(*) AS hits
  FROM my_mapdata
 WHERE ST_Intersects(
         geom,
         ST_GeomFromText(
           'POLYGON((-105.20 39.60, -104.70 39.60, -104.70 40.00, -105.20 40.00, -105.20 39.60))',
           4326));
