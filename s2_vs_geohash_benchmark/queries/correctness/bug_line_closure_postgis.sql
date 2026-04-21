-- bug_line_closure_postgis.sql
-- ============================================================================
-- CORRECTNESS DEMO: Open LineString vs. a square sitting in empty space.
--
-- The line is a C-shape with three segments - it never closes:
--
--     +----------+    LineString:  (0,0) -> (10,0) -> (10,10) -> (0,10)
--     |          |                 (no closing edge back to origin)
--     |  +----+  |
--     |  |    |  |    Square:      (2,2) -> (8,2) -> (8,8) -> (2,8) -> (2,2)
--     |  |    |  |                 fully inside the C's opening
--     |  +----+  |
--     |          |
--     +----------+
--
-- Physically, the line and the square do NOT touch.  PostGIS uses GEOS's
-- exact algorithm, recognises the line as open (no interior), and returns
-- the correct answer.
--
-- Expected:  f   (FALSE, disjoint)
-- ============================================================================
SELECT ST_Intersects(
  ST_GeomFromText('LINESTRING(0 0, 10 0, 10 10, 0 10)'),
  ST_GeomFromText('POLYGON((2 2, 8 2, 8 8, 2 8, 2 2))')
) AS intersects;
