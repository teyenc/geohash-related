-- Q6_s2_seqscan.sql : 10 nearest POIs to Fort Collins, CO (KNN).
-- S2 extension doing a Sequential Scan (identical SQL to Dan's/PostGIS).
-- ============================================================================
-- UNDER THE HOOD
-- ----------------------------------------------------------------------------
-- This query uses the exact same SQL syntax as Q6_postgis and Q6_dans:
--
--     ORDER BY geom <-> point LIMIT 10
--
-- In PostGIS, this is fast because the GiST index natively supports
-- distance-priority traversal.
--
-- In S2 (and Dan's Geohash), the spatial index is a B-Tree. A B-Tree
-- cannot sort by physical distance. Therefore, PostgreSQL must fall back
-- to a Sequential Scan:
--   1. Read all 344,688 rows.
--   2. Calculate the exact distance (`<->`) from the query point to every row.
--   3. Sort all 344,688 distances.
--   4. Return the top 10.
--
-- This file is included to prove that S2 *can* run the standard PostGIS
-- syntax, but it will be just as slow as Dan's Geohash because of the
-- B-Tree limitation.
--
-- To get index-accelerated KNN with S2, you must use the `spatial_knn()`
-- expanding-ring function (see Q6_s2.sql).
-- ============================================================================
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT md_pk,
       md_name,
       md_city,
       geom <-> ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326) AS dist
  FROM my_mapdata
 ORDER BY geom <-> ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)
 LIMIT 10;
