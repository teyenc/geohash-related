-- bug_line_closure_dans.sql
-- ============================================================================
-- CORRECTNESS DEMO: Open LineString vs. a square sitting in empty space.
--
-- Same geometry as the PostGIS / S2 versions.  Dan's pure-SQL ST_Intersects
-- (in `20 - sql/25_GeometryFunctions.sql:294-347`) walks the vertex
-- arrays and tests edge pairs using
--
--     i2 := CASE WHEN i = na THEN 1 ELSE i + 1 END;
--
-- When `i` reaches the last vertex, `i + 1` wraps back to vertex 1.
-- For a LineString this silently adds a synthetic closing edge from
-- (0, 10) back to (0, 0), turning the open C-shape into a closed
-- 10 x 10 rectangle.  The square at (2,2)..(8,8) is then inside that
-- synthetic rectangle, so Dan's "any vertex of B inside A?" branch
-- fires and returns TRUE.
--
-- Expected (from PostGIS/S2): f
-- Actual    (from Dan's):      t    <-- WRONG
-- ============================================================================
SELECT ST_Intersects(
  ST_GeomFromText('LINESTRING(0 0, 10 0, 10 10, 0 10)'),
  ST_GeomFromText('POLYGON((2 2, 8 2, 8 8, 2 8, 2 2))')
) AS intersects;
