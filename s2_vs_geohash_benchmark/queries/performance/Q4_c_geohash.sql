-- Q4_c_geohash.sql : COUNT of rivers (LineStrings) intersecting the
--                    western-US envelope.
-- ============================================================================
-- THIS IS THE QUERY THE WHOLE EXERCISE WAS ABOUT.
--
-- Dan's pre-c_geohash schema cannot index LineStrings (one geo_hash10 per
-- row, meaningless for a 75 km polyline) so Q4_dans.sql does a Seq Scan
-- and the plpgsql ST_Intersects runs on every one of the 100 000 rivers
-- (~57 s median).
--
-- With c_geohash + the (id, c_geo_cell) mapping table populated by the
-- c_geohash_auto_index trigger from a per-segment merged cover, this query
-- runs as a YB BATCHED NESTED-LOOP JOIN:
--
--    Aggregate
--      -> YB Batched Nested Loop Join
--           Hash Cond: rivers.id = candidates.id
--           -> SubPlan: SELECT cgeo_spatial_candidates('rivers', envelope)
--                          -> Index Scan rivers_cgeo_index (c_geo_cell BETWEEN ...)
--                             UNION ALL
--                             Index Scan rivers_cgeo_index (c_geo_cell = ANY(...))
--           -> Index Scan on rivers (pkey, batched)
--                Index Cond: id = ANY($batch::int8[])    -- ~yb_bnl_batch_size IDs/RPC
--
-- which is structurally identical to bench_s2's Q4 — only the cell-encoding
-- differs (int64 geohash with 5-bit shift vs. int64 S2 with 2-bit shift).
--
-- WHY `IN (SELECT ...)` AND NOT `= ANY(ARRAY(SELECT ...))`:
--   The ARRAY() wrapper materializes the candidate set into a constant
--   int8[] before the join. The planner then plans `id = ANY($1)` as a
--   SubPlan + Hashed-IN — that's a per-row array probe, not a join, so
--   YB BNL can NEVER fire. Dropping ARRAY() preserves the semijoin shape
--   and lets BNL kick in (~1000 IDs per DocDB RPC round-trip; see README
--   line 113 for why this is the dominant latency component on YB).
-- ============================================================================
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT count(*) AS rivers_in_west_us
  FROM rivers
 WHERE id IN (
         SELECT cgeo_spatial_candidates(
           'rivers',
           ST_MakeEnvelope(-125.0, 30.0, -100.0, 50.0, 4326)))
   AND ST_Intersects(
         geom,
         ST_MakeEnvelope(-125.0, 30.0, -100.0, 50.0, 4326));
