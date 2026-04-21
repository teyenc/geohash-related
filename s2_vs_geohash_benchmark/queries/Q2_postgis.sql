-- Q2_postgis.sql : COUNT of POIs within 50 km of Fort Collins, CO
-- ----------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT TEXT)
WITH anchor AS (
  SELECT ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326) AS pt
)
SELECT count(*) AS hits
  FROM my_mapdata, anchor
 WHERE ST_DWithin(geom::geography, anchor.pt::geography, 50000, true);
