-- bug_polygon_hole_dans.sql
-- ============================================================================
-- CORRECTNESS DEMO: Point-in-donut test.
--
-- Dan's `geometry` type is `(lon double[], lat double[])` - ONE flat array
-- pair per row.  There is no place to store a second ring for the hole.
-- This has two consequences:
--
--   (a) ST_GeomFromText rejects WKT that contains interior rings, because
--       Dan's plpgsql parser cannot split on the comma between rings.
--   (b) If you "work around" that by stripping the hole and passing only
--       the outer ring, ST_Contains silently returns TRUE - which is
--       wrong, because the real donut does NOT contain (5, 5).
--
-- Run both blocks below to see both failure modes.
--
-- Expected (from PostGIS/S2):  f
-- Actual (Dan's):  ERROR   on the full WKT,
--                  TRUE    on the hole-stripped WKT -> silently WRONG
-- ============================================================================

-- (a) Full WKT with a hole  -> ERROR
--     invalid input syntax for type double precision: "0)"
SELECT ST_Contains(
  ST_GeomFromText(
    'POLYGON((0 0, 10 0, 10 10, 0 10, 0 0), (3 3, 7 3, 7 7, 3 7, 3 3))'
  ),
  ST_GeomFromText('POINT(5 5)')
) AS contains_full;

-- (b) Strip the hole ("workaround")  -> TRUE (WRONG)
SELECT ST_Contains(
  ST_GeomFromText('POLYGON((0 0, 10 0, 10 10, 0 10, 0 0))'),
  ST_GeomFromText('POINT(5 5)')
) AS contains_no_hole;
