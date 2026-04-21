-- bug_polygon_hole_postgis.sql
-- ============================================================================
-- CORRECTNESS DEMO: Point-in-donut test.
--
-- A 10 x 10 outer square with a 4 x 4 hole punched in the middle.
-- The query point (5, 5) sits exactly in the hole.
--
--     +------------+            Outer ring:  (0,0) -> (10,0) -> (10,10) -> (0,10)
--     |            |            Inner ring:  (3,3) -> (7,3)  -> (7,7)   -> (3,7)
--     |   +----+   |
--     |   | (5,5)| |            Point (5,5) is INSIDE the inner hole,
--     |   |  .  |  |            therefore NOT contained by the donut.
--     |   +----+   |
--     |            |
--     +------------+
--
-- PostGIS parses both rings of the WKT and GEOS correctly subtracts the
-- hole.  ST_Contains returns FALSE.
--
-- Expected:  f   (FALSE - point is in the hole)
-- ============================================================================
SELECT ST_Contains(
  ST_GeomFromText(
    'POLYGON((0 0, 10 0, 10 10, 0 10, 0 0), (3 3, 7 3, 7 7, 3 7, 3 3))'
  ),
  ST_GeomFromText('POINT(5 5)')
) AS contains;
