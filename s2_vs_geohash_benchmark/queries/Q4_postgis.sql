-- Q4_postgis.sql : rivers that intersect the western-US envelope (~5x CA area)
-- PostGIS uses the GiST index on rivers(geom) for the ST_Intersects filter.
-- ----------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT TEXT)
SELECT count(*) AS rivers_in_west_us
  FROM rivers
 WHERE ST_Intersects(
         geom,
         ST_MakeEnvelope(-125.0, 30.0, -100.0, 50.0, 4326));
