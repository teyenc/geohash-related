-- Q3_postgis.sql : COUNT of POIs inside a 2.5 deg x 2.0 deg (~200 km x ~200 km)
-- box centered on the Colorado Front Range.
-- ----------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT TEXT)
SELECT count(*) AS hits
  FROM my_mapdata
 WHERE ST_Intersects(
         geom,
         ST_GeomFromText(
           'POLYGON((-106.20 38.80, -103.70 38.80, -103.70 40.80, -106.20 40.80, -106.20 38.80))',
           4326));
