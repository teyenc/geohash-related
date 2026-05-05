-- operator_bbox_overlap_postgis.sql
-- ============================================================================
-- THE BOUNDING BOX OVERLAP OPERATOR (&&)
-- 
-- PostGIS natively supports the `&&` operator using its GiST (R-Tree) index.
-- This allows the planner to instantly find geometries whose bounding boxes
-- overlap the query envelope.
--
-- Notice how the query is extremely simple and declarative:
--    WHERE geom && ST_MakeEnvelope(...)
--
-- Note: On this specific machine/dataset size, PostGIS sometimes chooses a 
-- Parallel Seq Scan because the result set (190,060 rows) is so large that 
-- it thinks scanning is faster. If you want to force the index scan to prove 
-- the GiST index works, uncomment the SET enable_seqscan = off; line.
-- ============================================================================

-- SET enable_seqscan = off;

\timing on
EXPLAIN (ANALYZE, VERBOSE, FORMAT TEXT)
SELECT count(*) 
FROM my_mapdata 
WHERE geom && ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326);
