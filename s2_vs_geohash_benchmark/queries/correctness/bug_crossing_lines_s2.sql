-- bug_crossing_lines_s2.sql
-- ============================================================================
-- CORRECTNESS DEMO: Two simple 2-vertex lines crossing in an X shape.
--
-- Same geometry as the PostGIS version.  Our yb_geospatial_s2 extension
-- delegates ST_Intersects to GEOS (C library), which handles any LineString
-- of 2 or more vertices natively.
--
-- Expected:  t   (TRUE)
-- ============================================================================
SELECT ST_Intersects(
  ST_GeomFromText('LINESTRING(0 0, 10 10)'),
  ST_GeomFromText('LINESTRING(0 10, 10 0)')
) AS intersects;
