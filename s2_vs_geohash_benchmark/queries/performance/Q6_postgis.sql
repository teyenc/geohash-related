-- Q6_postgis.sql : 10 nearest POIs to Fort Collins, CO (KNN).
-- PostGIS reference implementation using the GiST index and the <-> operator.
-- ============================================================================
-- UNDER THE HOOD
-- ----------------------------------------------------------------------------
-- ORDER BY geom <-> point LIMIT 10 is the canonical PostGIS KNN pattern.
--
-- The GiST R-tree natively supports distance-priority traversal:
--   1. Start at the root, compute min-possible-distance from the query point
--      to each child bounding box.
--   2. Pop the closest unexplored box off a priority queue and descend.
--   3. When a leaf is reached, compute the exact ST_Distance and compare to
--      the current top-K candidates.
--   4. Stop as soon as the priority queue's next box is farther than the
--      10th best exact distance found so far.
--
-- This is O(log N + k) in practice.  No sequential scan, no radius guess.
-- The <-> operator is what signals this intent to the planner.
--
-- Expected latency on 344k POIs: ~30-80 ms.
-- ============================================================================
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT TEXT)
SELECT md_pk,
       md_name,
       md_city,
       geom <-> ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326) AS dist_deg
  FROM my_mapdata
 ORDER BY geom <-> ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)
 LIMIT 10;
