-- bug_crossing_lines_postgis.sql
-- ============================================================================
-- CORRECTNESS DEMO: Two simple 2-vertex lines crossing in an X shape.
--
-- Geometry:
--
--     (0,10) \          / (10,10)
--             \        /
--              \      /
--               \    /
--                \  /
--                 \/  <- cross point at (5, 5)
--                 /\
--                /  \
--               /    \
--              /      \
--             /        \
--     (0,0) /          \ (10,0)
--
-- Line A: (0,0)   -> (10,10)     <- a simple 2-vertex line
-- Line B: (0,10)  -> (10,0)      <- another simple 2-vertex line
--
-- They clearly cross at (5, 5).  ST_Intersects should return TRUE.
--
-- PostGIS uses the GEOS segment-segment intersection algorithm; it handles
-- any LineString with 2 or more vertices natively.
--
-- Expected:  t   (TRUE)
-- ============================================================================
SELECT ST_Intersects(
  ST_GeomFromText('LINESTRING(0 0, 10 10)'),
  ST_GeomFromText('LINESTRING(0 10, 10 0)')
) AS intersects;
