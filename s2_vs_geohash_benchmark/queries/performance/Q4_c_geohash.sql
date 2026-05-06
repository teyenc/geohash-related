-- ============================================================================
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
-- With c_geohash + the (id, geohash) text mapping table populated by
-- bbox-cover at index_prec=5 (see 04_setup_yb_cgeo.sh), this query runs
-- as a YB BATCHED NESTED-LOOP JOIN:
--
--    Aggregate
--      -> YB Batched Nested Loop Join
--           Hash Cond: rivers.id = candidates.id
--           -> SubPlan: SELECT cgeo_text_spatial_candidates('rivers', envelope, 4)
--                          -> Index Scan rivers_cgeo_index
--                             (geohash BETWEEN $rmin AND $rmax  per pair)
--           -> Index Scan on rivers (pkey, batched)
--                Index Cond: id = ANY($batch::int8[])    -- ~yb_bnl_batch_size IDs/RPC
--
-- which is structurally identical to bench_s2's Q4 — only the cell
-- encoding (and storage type, text vs int64) differs.
--
-- WHY `IN (SELECT ...)` AND NOT `= ANY(ARRAY(SELECT ...))`:
--   The ARRAY() wrapper materializes the candidate set into a constant
--   int8[] before the join. The planner then plans `id = ANY($1)` as a
--   SubPlan + Hashed-IN — that's a per-row array probe, not a join, so
--   YB BNL can NEVER fire. Dropping ARRAY() preserves the semijoin shape
--   and lets BNL kick in (~1000 IDs per DocDB RPC round-trip; see README
--   line 113 for why this is the dominant latency component on YB).
--
-- Query precision: 4. Rivers are indexed at level 5; query precision
-- must be ≤ index precision (right-pad-with-0 has no level marker).
-- Continental query bbox at level 4 produces ~10-20 ranges after merge.
--
-- Expected hit count: 32 489 (verified via full-scan ST_Intersects).
-- ============================================================================
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT count(*) AS rivers_in_west_us
  FROM rivers
 WHERE id IN (
         SELECT cgeo_text_spatial_candidates(
           'rivers',
           ST_MakeEnvelope(-125.0, 30.0, -100.0, 50.0, 4326), 4))
   AND ST_Intersects(
         geom,
         ST_MakeEnvelope(-125.0, 30.0, -100.0, 50.0, 4326));
