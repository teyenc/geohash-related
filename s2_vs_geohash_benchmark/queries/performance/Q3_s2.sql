-- Q3_s2.sql : COUNT of POIs inside a 2.5 deg x 2.0 deg (~200 km x ~200 km)
-- Colorado Front Range box.
-- ============================================================================
-- UNDER THE HOOD
-- ----------------------------------------------------------------------------
-- spatial_candidates('my_mapdata', envelope) internally does:
--
--   1)  query_cells = ST_S2Covering(envelope, 10, 20)
--       For this ~200 km box the coverer returns 130 int8 cells at
--       *mixed levels*.  The coverer fills the interior with fine cells
--       and then S2CellUnion::Normalize() merges any 4 same-level
--       siblings into their parent, giving a tight mixed-level covering.
--       Actual level distribution for Q3:
--           level  7 (~66 km):    4 cells
--           level  8 (~33 km):   18
--           level  9 (~16 km):   25
--           level 10 ( ~8 km):   77   <- near the min_level=10 floor
--           level 11 ( ~4 km):    5
--           level 12 ( ~2 km):    1
--       The first cell (Hilbert-ordered) is:
--
--           cell  = -8713738501775949824   (level 10, ~8 km)
--
--   2)  For each of the 130 cells, spatial_candidates emits:
--
--           SELECT id FROM my_mapdata_s2_index
--            WHERE s2_cell BETWEEN -8713739601287577599    -- range_min
--                              AND -8713737402264322049    -- range_max
--           UNION ALL
--           SELECT id FROM my_mapdata_s2_index
--            WHERE s2_cell = ANY(ARRAY[
--              -8714465278961909760,   -- level 9 parent
--              -8713743999334088704,   -- level 8
--              -8713739601287577600,   -- level 7
--              -8713691222775955456,   -- level 6
--              -8713620854031777792,   -- level 5
--              -8713339379055067136    -- level 4 (walker stops)
--            ]::int8[]);
--
--       range_min / range_max are computed bitwise from the cell:
--           range_min = cell - (lsb(cell) - 1)
--           range_max = cell + (lsb(cell) - 1)
--       where lsb(x) = x & (-x).  This is the Hilbert-curve interval
--       containing all descendants of the cell at every finer level.
--
--   3)  Total index work: 130 BETWEEN range scans + 130 ANY(array) probes
--       against the range-sharded B-tree - 260 distributed index
--       operations vs Dan's 2 726 B-tree probes (1/21 the fan-out).
--
-- Phase 2: Batched Nested Loop Join fetches ~191 k candidate rows; the
-- exact ST_Intersects recheck in GEOS keeps 190 060 (matches PostGIS).
-- Dan's, running the same Phase 2 count in interpreted plpgsql, is
-- roughly 2x slower per row on top of the index-fan-out advantage.
-- ============================================================================
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT count(*) AS hits
  FROM my_mapdata
 WHERE md_pk IN (
         SELECT spatial_candidates(
           'my_mapdata',
           ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326))
       )
   AND ST_Intersects(
         geom,
         ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326));
