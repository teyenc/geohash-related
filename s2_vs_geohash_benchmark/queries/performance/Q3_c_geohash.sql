-- Q3_c_geohash.sql : COUNT of POIs in the ~200 km Colorado Front Range box.
-- ============================================================================
-- Same shape as Q3_s2.sql; explicit cgeo_text_spatial_candidates injection.
-- Polygon recheck via ST_Intersects (GEOS).
--
-- Storage: my_mapdata_cgeo_index(id, geohash) at index_prec=10.
-- Query precision: 5 (~5 km × 5 km cells). 5 ≤ 10. The ~200 km box covers
-- ~40 × 40 = 1 600 leaf cells before merging; the prefix-merge collapses
-- interior 32-tuples so the actual range count is much smaller.
--
-- Expected hit count: 190 060 (verified via full-scan ST_Intersects).
-- ============================================================================
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT count(*) AS hits
  FROM my_mapdata
 WHERE md_pk IN (
         SELECT cgeo_text_spatial_candidates(
           'my_mapdata',
           ST_GeomFromText(
             'POLYGON((-106.20 38.80, -103.70 38.80, -103.70 40.80, '
             '-106.20 40.80, -106.20 38.80))', 4326), 5))
   AND ST_Intersects(
         geom,
         ST_GeomFromText(
           'POLYGON((-106.20 38.80, -103.70 38.80, -103.70 40.80, '
           '-106.20 40.80, -106.20 38.80))', 4326));
