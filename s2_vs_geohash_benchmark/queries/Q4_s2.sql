-- Q4_s2.sql : rivers that intersect the western-US envelope (~5x CA area)
-- ============================================================================
-- UNDER THE HOOD
-- ----------------------------------------------------------------------------
-- The secret sauce of the S2 mapping table is that it indexes lines /
-- polygons the same way it indexes points.
--
-- LOAD TIME  (setup/03_setup_rivers.sh):
--
--     INSERT INTO rivers_s2_index (id, s2_cell)
--     SELECT id, unnest(ST_S2Covering(geom, 10, 20))
--       FROM rivers;
--
-- ST_S2Covering on a 15-vertex LineString returns ~8 S2 cells covering the
-- line's path.  100 000 rivers produced ~800 000 rows in rivers_s2_index.
-- Each river effectively "writes itself into" every S2 cell its line
-- passes through.
--
-- QUERY TIME:
--
-- Step 1  -- get the S2 covering of the query envelope:
--
--     SELECT unnest(ST_S2Covering(
--              ST_MakeEnvelope(-125.0, 30.0, -100.0, 50.0, 4326),
--              10, 20));    -- min_level=10, max_level=20
--     --  -> 1 383 int8 cells:
--     --     5968434988591349760, 5968443784684371968, ...,
--     --     6015767864655478784, 6015769032886583296
--
-- Step 2  -- Normalize() in the coverer distributes those cells across
-- mixed levels to match the envelope's shape without padding:
--
--     SELECT 30 - (floor(ln(cell & -cell) / ln(2))::int / 2) AS level,
--            count(*)
--       FROM unnest(ST_S2Covering(...)) cell GROUP BY level;
--     --   level |   n           (S2 edge)
--     --   ------+------      -------------
--     --     3   |   1         ~1 250 km
--     --     4   |   6           ~500 km
--     --     5   |   9           ~250 km
--     --     6   |  21           ~125 km
--     --     7   |  57            ~66 km
--     --     8   | 182            ~33 km
--     --     9   | 362            ~16 km
--     --    10   | 626             ~8 km    <- min_level floor
--     --    11   |  60             ~4 km
--     --   12+   |  59          ~2 km-finer
--
-- Step 3  -- for each of the 1 383 cells, spatial_candidates runs:
--
--     SELECT id FROM rivers_s2_index
--      WHERE s2_cell BETWEEN (cell - (lsb - 1))
--                        AND (cell + (lsb - 1))    -- lsb = cell & (-cell)
--     UNION ALL
--     SELECT id FROM rivers_s2_index
--      WHERE s2_cell = ANY(<ancestors>::int8[]);   -- walks up to level 4
--
-- (See Q2_s2.sql for a fully-expanded example with literal numbers.)
-- Total: 1 383 BETWEEN range scans + 1 383 ANY(array) probes against
-- the range-sharded B-tree, packed by YB's Batched Nested Loop Join
-- into a handful of DocDB round-trips.
--
-- Step 4  -- exact recheck in GEOS:
--
--     SELECT count(*) FROM rivers
--      WHERE id IN (<candidate_ids>)
--        AND ST_Intersects(geom,
--                          ST_MakeEnvelope(-125, 30, -100, 50, 4326));
--     --  32 612 candidates in  -> 32 489 pass
--     --  (covering precision ~99.6 %: only 123 false positives)
--
-- WHY S2 STILL WINS DESPITE 1 383 CELLS:
--
--      Engine      Q4 latency    Why
--      ----------  ----------    ------------------------------------------
--      PostGIS       ~80 ms      GiST index, local, no RPC
--      S2 (ours)  ~1 800 ms      1 383 BETWEEN scans + GEOS on 32 612 rows
--      Dan's     ~57 500 ms      Seq Scan over 100 000 + plpgsql recheck
--
-- Dan's can't escape the Seq Scan because his schema stores a single
-- geohash per row (meaningless for a multi-cell line).  He'd need to
-- build exactly the kind of (row_id, cell) mapping table we already have.
--
-- Knob worth exposing in production: `min_level` in ST_S2Covering.  Our
-- extension pins it to 10, which is the right trade-off for POI / point
-- workloads (Q1 gets 9 cells, not 1).  For continent-scale queries,
-- lowering min_level to 4-5 would collapse Q4's covering from 1 383 cells
-- down to tens of cells, at the cost of more candidates in Phase 2 for
-- small queries.  A per-call parameter would let each workload pick.
-- ============================================================================
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT count(*) AS rivers_in_west_us
  FROM rivers
 WHERE id IN (
         SELECT spatial_candidates(
           'rivers',
           ST_MakeEnvelope(-125.0, 30.0, -100.0, 50.0, 4326))
       )
   AND ST_Intersects(
         geom,
         ST_MakeEnvelope(-125.0, 30.0, -100.0, 50.0, 4326));
