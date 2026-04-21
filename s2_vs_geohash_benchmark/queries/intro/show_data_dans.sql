-- show_data_dans.sql
-- ============================================================================
-- Prove that bench_dans holds real data.
-- Run this in the Dan's ysqlsh terminal before the demo.
-- ============================================================================
\echo '--- 5 sample POIs with Dan''s precomputed geohash strings:'
SELECT md_pk, md_name, md_city, geo_hash10, geo_hash8
  FROM my_mapdata
 LIMIT 5;

\echo ''
\echo '--- What Dan''s geometry physically stores (composite type: lon[], lat[]):'
SELECT md_pk, md_name,
       (geom).lon[1] AS first_lon,
       (geom).lat[1] AS first_lat
  FROM my_mapdata
 LIMIT 3;

\echo ''
\echo '--- 3 sample rivers (variable-length lon[]/lat[] arrays):'
SELECT id, name,
       array_length((geom).lon, 1) AS n_vertices,
       (geom).lon[1:2]            AS lon_first_2,
       (geom).lat[1:2]            AS lat_first_2
  FROM rivers
 LIMIT 3;

\echo ''
\echo '--- Row counts:'
SELECT 'my_mapdata' AS tbl, (SELECT count(*) FROM my_mapdata) AS rows
UNION ALL
SELECT 'rivers',            (SELECT count(*) FROM rivers);
