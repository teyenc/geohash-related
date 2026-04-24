-- Q6_dans.sql : 10 nearest POIs to Fort Collins, CO (KNN).
-- Dan's pure-SQL geohash extension.
-- ============================================================================
-- UNDER THE HOOD
-- ----------------------------------------------------------------------------
-- Dan's extension DOES define the `<->` operator for (geometry, geometry)
-- -- see `geospatial_v05/20 - sql/10_CreateGeometryType.sql:774-781`.  The
-- backing function is a plpgsql centroid-to-centroid planar distance.
--
-- But Dan's own comment at line 743 of that same file admits the catch:
--
--     "In PostGIS this is index-accelerated; here it is a plain
--      distance calculation."
--
-- The three functional indexes Dan ships (ix_mapdata3, ix_mapdata4,
-- ix_mapdata_geo_hash8) are B-trees keyed on truncated geohash *strings*.
-- They cannot sort rows by distance from a query point -- a string B-tree
-- has no notion of 2D proximity.
--
-- So the canonical PostGIS idiom
--
--     ORDER BY geom <-> point LIMIT 10
--
-- parses and returns correct answers, but falls back to:
--   1.  Seq Scan on every one of the 344 688 rows.
--   2.  Evaluate `geom <-> point` on each row -- a plpgsql centroid-
--       distance computation over the (lon[], lat[]) composite type.
--   3.  Top-N heapsort the results to keep just 10.
--
-- This is the classic KNN foot-gun: the SQL looks identical to
-- PostGIS's, returns the right 10 POIs, but has no indexing path.
-- Scales linearly with row count; at 10 M POIs this would be a
-- minute-plus query.
--
-- PostGIS solves it with GiST distance-priority traversal (see Q6_postgis).
-- Our S2 extension solves it with the spatial_knn() expanding-ring
-- helper (see Q6_s2) because our `<->` has the same limitation Dan's
-- does -- a B-tree spatial index cannot traverse in distance order.
-- ============================================================================
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT md_pk,
       md_name,
       md_city,
       geom <-> ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326) AS dist
  FROM my_mapdata
 ORDER BY geom <-> ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)
 LIMIT 10;
