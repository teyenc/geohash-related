-- Q3_postgis.sql : COUNT of POIs inside a 2.5 deg x 2.0 deg (~200 km x ~200 km)
-- box centered on the Colorado Front Range.
-- ============================================================================
-- UNDER THE HOOD
-- ----------------------------------------------------------------------------
-- ST_Intersects(geom, POLYGON) uses a *planar* path when both sides are
-- geometry (not geography), so PostGIS uses the 2D GiST index on geom
-- (`ix_my_mapdata_geom_gist`) rather than the geography index:
--
--   Phase 1  (GiST MBR test via the `&&` operator):
--     Index returns every row whose geometry bounding box overlaps the
--     query polygon's bbox.  Because the query shape is itself a
--     rectangle, the MBR test and the exact test agree on the boundary -
--     no "candidate but rejected" tail.
--
--   Phase 2  (exact ST_Intersects):
--     For the rectangle case this simplifies to "is the point's lat/lon
--     inside the rectangle?", done entirely in GEOS C code.
--
-- On a 2.5 deg x 2.0 deg box this returns a big result set (~100k rows),
-- so PostgreSQL parallelizes: Parallel Bitmap Heap Scan across workers.
-- ============================================================================
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT TEXT)
SELECT count(*) AS hits
  FROM my_mapdata
 WHERE ST_Intersects(
         geom,
         ST_GeomFromText(
           'POLYGON((-106.20 38.80, -103.70 38.80, -103.70 40.80, -106.20 40.80, -106.20 38.80))',
           4326));
