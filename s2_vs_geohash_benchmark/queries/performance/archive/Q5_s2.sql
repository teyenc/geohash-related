-- Q5_s2.sql : COUNT of POIs whose bounding box overlaps the Colorado Front
-- Range box, using the PostGIS && operator.
-- ============================================================================
-- IDENTICAL SQL TO Q5_postgis.sql.
--
-- Our planner hook recognises the `geom && envelope` operator and
-- transparently injects
--
--    AND md_pk = ANY(SELECT spatial_candidates('my_mapdata', envelope))
--
-- so the standard planner does an Index Scan over my_mapdata_s2_index.
-- Without this hook the query would fall back to a Seq Scan because YB
-- has no GiST index, and Dan's geohash B-tree cannot answer && either.
-- ============================================================================

\timing on
EXPLAIN (ANALYZE, VERBOSE, FORMAT TEXT)
SELECT count(*)
FROM my_mapdata
WHERE geom && ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326);
