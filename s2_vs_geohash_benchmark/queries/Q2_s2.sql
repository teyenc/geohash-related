-- Q2_s2.sql : COUNT of POIs within 50 km of Fort Collins, CO
-- ============================================================================
-- UNDER THE HOOD
-- ----------------------------------------------------------------------------
-- spatial_candidates('my_mapdata', envelope) internally does:
--
--   1)  query_cells = ST_S2Covering(envelope, 10, 20)
--       For this ~130 km x ~110 km envelope the coverer returns 53 int8
--       cells (mixed levels, all Hilbert-ordered).  The first cell is:
--
--           cell  = -8689481076243955712
--
--   2)  For each of the 53 cells, spatial_candidates emits two separate
--       SELECTs joined by UNION ALL.  For cell #1 the generated SQL is
--       literally:
--
--           SELECT id FROM my_mapdata_s2_index
--            WHERE s2_cell BETWEEN -8689482175755583487    -- range_min
--                              AND -8689479976732327937    -- range_max
--           UNION ALL
--           SELECT id FROM my_mapdata_s2_index
--            WHERE s2_cell = ANY(ARRAY[
--              -8689484374778839040,   -- level 9 parent
--              -8689479976732327936,   -- level 8
--              -8689466782592794624,   -- level 7
--              -8689414006034661376,   -- level 6
--              -8688569581104529408,   -- level 5
--              -8687443681197686784    -- level 4 (walker's stop level)
--            ]::int8[]);
--
--       The BETWEEN is a tight range on the range-sharded B-tree
--       `(s2_cell ASC, id)` - single-tablet scan, catches every descendant.
--       The ANY(array) is 6 point probes catching any ancestor (matters for
--       large geometries only; POIs have no ancestors in the index).
--
--       UNION ALL (not OR) because YB has no BitmapOr executor: a single
--       OR would degrade to a Seq Scan over the whole mapping table.
--
--   3)  The same shape repeats for all 53 cells, so the total index work
--       is 53 BETWEEN scans + 53 ANY(array) probes.
--
-- Cell-count scaling vs Dan's:
--
--      Query            Dan (prec 5)   S2 (min=10, max=20)
--      -------------    ------------   -------------------
--      Q1  (5 km)             16              9
--      Q2  (50 km)           644             53
--      Q3  (200 km box)    2 726            130
--      Q4  (western US)    n/a (no idx)   1 383
--
-- Dan's cell count scales roughly linearly with bbox area; S2's coverer
-- adapts cell size so a Q2 that is 100x the area of Q1 only needs ~6x
-- more cells.
--
-- Phase 2: Batched Nested Loop Join fetches the 30 337 candidate main-
-- table rows, then ST_DistanceSphere(geom, POINT) <= 50 000 keeps 25 337.
-- ============================================================================
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT count(*) AS hits
  FROM my_mapdata
 WHERE md_pk IN (
         SELECT spatial_candidates(
           'my_mapdata',
           ST_MakeEnvelope(-105.68, 40.08, -104.48, 41.08, 4326))
       )
   AND ST_DistanceSphere(geom,
                         ST_GeomFromText('POINT(-105.0775 40.5853)', 4326)) <= 50000;
