-- show_data_postgis.sql
-- ============================================================================
-- Prove that bench_postgis holds real data.
-- Run this in the PostGIS psql terminal before the demo.
-- ============================================================================
\echo '--- 5 sample POIs (PostGIS native geometry, rendered via ST_AsText):'
SELECT md_pk, md_name, md_city, ST_AsText(geom) AS geom
  FROM my_mapdata
 LIMIT 5;

\echo ''
\echo '--- 3 sample rivers (each a 15-vertex LineString; bbox shown):'
SELECT id, name,
       ST_NPoints(geom)            AS n_vertices,
       ST_AsText(ST_Envelope(geom)) AS bbox
  FROM rivers
 LIMIT 3;

\echo ''
\echo '--- Row counts + on-disk size:'
SELECT 'my_mapdata' AS tbl,
       (SELECT count(*) FROM my_mapdata) AS rows,
       pg_size_pretty(pg_total_relation_size('my_mapdata')) AS size
UNION ALL
SELECT 'rivers',
       (SELECT count(*) FROM rivers),
       pg_size_pretty(pg_total_relation_size('rivers'));
