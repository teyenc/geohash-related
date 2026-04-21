-- bug_line_closure_s2.sql
-- ============================================================================
-- CORRECTNESS DEMO: Open LineString vs. a square sitting in empty space.
--
-- Same geometry as the PostGIS version.  Our yb_geospatial_s2 extension
-- delegates ST_Intersects to GEOS (C library), so the line is correctly
-- treated as open - no synthetic closing edge is added.
--
-- Expected:  f   (FALSE, disjoint)
-- ============================================================================
SELECT ST_Intersects(
  ST_GeomFromText('LINESTRING(0 0, 10 0, 10 10, 0 10)'),
  ST_GeomFromText('POLYGON((2 2, 8 2, 8 8, 2 8, 2 2))')
) AS intersects;
