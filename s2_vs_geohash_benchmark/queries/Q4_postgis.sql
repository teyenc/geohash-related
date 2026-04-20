-- Q4_postgis.sql : rivers that intersect the California envelope
-- PostGIS uses the GiST index on rivers(geom) for the ST_Intersects filter.
-- ----------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT TEXT)
SELECT count(*) AS rivers_in_ca
  FROM rivers
 WHERE ST_Intersects(
         geom,
         ST_MakeEnvelope(-124.4, 32.5, -114.1, 42.0, 4326));
