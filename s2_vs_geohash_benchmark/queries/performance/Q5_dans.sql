-- operator_bbox_overlap_dans.sql
-- ============================================================================
-- THE BOUNDING BOX OVERLAP OPERATOR (&&)
-- 
-- Dan's pure-SQL architecture implements the `&&` operator math natively.
-- (It compares the min/max values of the `lon[]` and `lat[]` arrays inside
-- the composite type). 
--
-- However, there is NO WAY to index this operator. A B-Tree on a string
-- cannot handle a bounding box query. 
--
-- Notice the EXPLAIN output: 
--     Seq Scan on my_mapdata
--
-- Because the planner cannot use the Geohash index, it falls back to scanning 
-- every single row (344,688 rows) and evaluating the `&&` math on each one.
--
-- This is why `&&` is categorized as "3 - Not Supported by Geohash efficiently".
-- The math works, but without an index, the query cannot scale to large 
-- tables without devastating latency.
-- ============================================================================

\timing on
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT count(*) 
FROM my_mapdata 
WHERE geom && ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326);
