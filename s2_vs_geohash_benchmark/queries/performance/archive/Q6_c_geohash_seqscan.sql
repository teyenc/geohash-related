-- Q6_c_geohash_seqscan.sql : 10 nearest POIs to Fort Collins (KNN).
-- The "naive" foot-gun version on c_geohash, mirror of Q6_s2_seqscan.sql.
-- ============================================================================
-- WHY THIS IS A FOOT-GUN
-- ----------------------------------------------------------------------------
-- A B-tree keyed on a geohash int64 cell ID stores rows in Z-order
-- (Hilbert-curve-ish), NOT in Euclidean distance order from any query
-- point.  PostGIS's GiST R-tree IS distance-priority and can drive
-- ORDER BY <-> LIMIT k in O(log N + k).  The c_geohash B-tree cannot.
--
-- Submitting the canonical PostGIS idiom against bench_cgeo:
--
--     SELECT md_pk
--       FROM my_mapdata
--      ORDER BY geom <-> ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)
--      LIMIT 10;
--
-- ...is correct (returns the right 10 POIs) but the planner has no
-- way to use my_mapdata_cgeo_index for ordering, so it falls back to:
--
--     1.  Seq Scan on every one of the 344 688 rows.
--     2.  Evaluate `geom <-> point` on each row (centroid-distance).
--     3.  Top-N heapsort to keep just 10.
--
-- This is the same shape as Q6_s2_seqscan.sql and Q6_dans.sql.  To get
-- index-accelerated KNN with c_geohash, use the radius-bounded form in
-- Q6_c_geohash.sql instead.
-- ============================================================================
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT md_pk,
       md_name,
       md_city,
       geom <-> ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326) AS dist_deg
  FROM my_mapdata
 ORDER BY geom <-> ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)
 LIMIT 10;
