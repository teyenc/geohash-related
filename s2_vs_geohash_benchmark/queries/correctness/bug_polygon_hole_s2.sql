-- bug_polygon_hole_s2.sql
-- ============================================================================
-- CORRECTNESS DEMO: Point-in-donut test.
--
-- Same geometry as the PostGIS version.  Our yb_geospatial_s2 extension
-- uses GEOS for ST_Contains, so interior rings are handled natively and
-- the point (5, 5) is correctly reported as NOT contained by the donut.
--
-- Expected:  f   (FALSE - point is in the hole)
-- ============================================================================
SELECT ST_Contains(
  ST_GeomFromText(
    'POLYGON((0 0, 10 0, 10 10, 0 10, 0 0), (3 3, 7 3, 7 7, 3 7, 3 3))'
  ),
  ST_GeomFromText('POINT(5 5)')
) AS contains;
