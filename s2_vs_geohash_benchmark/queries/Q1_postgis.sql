-- Q1_postgis.sql : 10 nearest POIs within 1 km of Fort Collins, CO
-- PostGIS reference implementation using geography + GiST.
-- ----------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT TEXT)
WITH anchor AS (
  SELECT ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326) AS pt
)
SELECT md_pk,
       md_name,
       md_city,
       ST_Distance(geom::geography, anchor.pt::geography, true) AS dist_m
  FROM my_mapdata, anchor
 WHERE ST_DWithin(geom::geography, anchor.pt::geography, 1000, true)
 ORDER BY dist_m
 LIMIT 10;
