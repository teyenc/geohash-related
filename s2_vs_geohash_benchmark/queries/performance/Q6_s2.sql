-- Q6_s2.sql : 10 nearest POIs to Fort Collins, CO (KNN).
-- yb_geospatial_s2 extension: expanding S2 ring search via spatial_knn().
-- ============================================================================
-- UNDER THE HOOD
-- ----------------------------------------------------------------------------
-- YB's B-tree-based spatial index does NOT support distance-priority
-- traversal the way PostGIS's GiST R-tree does.  Writing the canonical
--
--     ORDER BY geom <-> point LIMIT 10
--
-- would correctly return the 10 nearest rows, but the planner would Seq-
-- Scan the whole table and top-N heapsort.  That is the same foot-gun
-- Dan's geohash hits -- see Q6_dans.sql for the Seq-Scan plan.
--
-- spatial_knn() avoids the foot-gun by standing on top of the S2 mapping
-- table:
--
--   1.  Pick a starting radius (default 100 m).
--   2.  Build a lat-aware bbox envelope around the query point.
--   3.  Call spatial_candidates() on the envelope -- one BETWEEN range
--       scan + one ANY(ancestors) probe per S2 covering cell.
--   4.  Filter those candidates by ST_DistanceSpheroid <= radius and
--       LIMIT k.  If >= k qualify we stop, else double the radius.
--   5.  Final pass: ORDER BY ST_DistanceSpheroid ASC LIMIT k against
--       the settled envelope.
--
-- Correctness: at loop exit all k candidates have distance <= radius, so
-- any row outside the envelope is farther than our k-th smallest and
-- cannot be in the true top-k.
--
-- Typical iterations: 1-3 on a dense POI dataset, up to ~6 on sparse
-- rural queries.  The LIMIT k inside the probe short-circuits the count,
-- so each iteration is only a few B-tree probes.
--
-- Expected latency on 344k POIs: ~200-500 ms (dominated by the S2
-- mapping-table range scans + the exact ST_DistanceSpheroid recheck).
-- ============================================================================
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT t.md_pk,
       t.md_name,
       t.md_city,
       knn.dist_meters
  FROM spatial_knn(
         'my_mapdata',
         ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326),
         10,
         'md_pk'          -- PK column of my_mapdata
       ) AS knn
  JOIN my_mapdata AS t ON t.md_pk = knn.id
 ORDER BY knn.dist_meters;
