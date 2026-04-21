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
--   1)  ST_S2Covering(western_us_envelope, 10, 20) returns 1 383 int8
--       cells.  The S2 coverer emits fine cells and then
--       S2CellUnion::Normalize() merges 4 same-level siblings into
--       their parent wherever possible, so the final covering uses
--       mixed levels adapted to the envelope's shape:
--
--           level  3 (~1 250 km):    1 cell    <- most of the interior
--           level  4 (~500 km):      6
--           level  5 (~250 km):      9
--           level  6 (~125 km):     21
--           level  7 (~66 km):      57
--           level  8 (~33 km):     182
--           level  9 (~16 km):     362
--           level 10 ( ~8 km):     626         <- edge-hugging cells
--           level 11 ( ~4 km):      60
--           level 12+  (~2 km or finer):   59
--
--       A 5.5 M km^2 envelope genuinely needs ~1 400 Hilbert-curve
--       intervals to tile without padding - even with mixed levels.
--       A handful of representative cell IDs:
--
--           5968434988591349760   5968443784684371968   5968452580777394176
--                                             ...
--           6015540282928398336   6015767864655478784   6015769032886583296
--
--   2)  For each of the 1 383 cells, spatial_candidates emits the same
--       BETWEEN + ANY(ancestors) UNION ALL shape shown in Q1/Q2/Q3
--       (just with cell-specific numbers).  Total index work:
--       1 383 BETWEEN range scans + 1 383 ANY(array) probes against
--       the range-sharded B-tree.  YB's Batched Nested Loop Join packs
--       these into a small number of DocDB round-trips.
--
--   3)  32 612 candidate rivers emerge from the index.  Phase 2 runs
--       the exact ST_Intersects(geom, envelope) through GEOS (C);
--       32 489 pass (only 123 rejected by the exact test - i.e. the
--       covering is already ~99.6 % precise for this workload).  The
--       final count matches PostGIS to the row.
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
