-- show_data_s2.sql
-- ============================================================================
-- Prove that bench_s2 holds real data, including the S2 mapping tables.
-- Run this in the S2 ysqlsh terminal before the demo.
-- ============================================================================
\echo '--- 5 sample POIs (yb_geospatial_s2 geometry, rendered via ST_AsText):'
SELECT md_pk, md_name, md_city, ST_AsText(geom) AS geom
  FROM my_mapdata
 LIMIT 5;

\echo ''
\echo '--- 5 rows from the POI S2 mapping table (one row per POI covering cell):'
SELECT entry_id, s2_cell
  FROM my_mapdata_s2_index
 LIMIT 5;

\echo ''
\echo '--- 3 rivers + how many mapping-table rows each one writes (~8 per river):'
SELECT entry_id, count(*) AS cells_per_river
  FROM rivers_s2_index
 GROUP BY entry_id
 ORDER BY entry_id
 LIMIT 3;

\echo ''
\echo '--- Row counts (notice mapping tables are larger than base tables):'
SELECT 'my_mapdata'            AS tbl, count(*) AS rows FROM my_mapdata
UNION ALL SELECT 'my_mapdata_s2_index',   count(*) FROM my_mapdata_s2_index
UNION ALL SELECT 'rivers',                count(*) FROM rivers
UNION ALL SELECT 'rivers_s2_index',       count(*) FROM rivers_s2_index;
