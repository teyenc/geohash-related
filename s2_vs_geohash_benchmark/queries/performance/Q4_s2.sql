-- Q4_s2.sql : COUNT of rivers (LineStrings) intersecting the western-US envelope.
-- ============================================================================
-- IDENTICAL SQL TO Q4_postgis.sql.
--
-- Our planner hook recognises the ST_Intersects(geom, envelope) predicate
-- and transparently injects
--
--    AND id = ANY(SELECT spatial_candidates('rivers', envelope))
--
-- so the standard planner does an Index Scan over rivers_s2_index instead
-- of a sequential scan.  Dan's geohash extension cannot index lines, so on
-- bench_dans this exact query falls back to a full Seq Scan over 100k rivers.
-- ============================================================================
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT count(*) AS rivers_in_west_us
  FROM rivers
 WHERE ST_Intersects(
         geom,
         ST_MakeEnvelope(-125.0, 30.0, -100.0, 50.0, 4326));
