-- Q4_dans.sql : rivers that intersect the western-US envelope (~5x CA area)
-- ============================================================================
-- UNDER THE HOOD
-- ----------------------------------------------------------------------------
-- This is where Dan's architecture breaks down.  His schema stores a single
-- geo_hash10 per row, which was populated from the row's one (lat, lon).
-- That works for a POI (one point = one geohash), but a river is a
-- LineString spanning 15 vertices across ~75 km - there is no single
-- geohash that represents it.  You would need a separate
-- `(river_id, geohash)` mapping table with a trigger, which Dan did not
-- build (the rivers table in bench_dans has NO index by design).
--
-- With no usable index, the planner falls back to:
--
--     Seq Scan on rivers
--       Filter: ST_Intersects(geom, polygon)
--
-- So every one of the 100 000 rivers runs through Dan's plpgsql
-- ST_Intersects.  His algorithm:
--
--   1. Close the LineString into a "degenerate polygon" by connecting its
--      last vertex back to its first (this accidentally produces mostly-
--      correct results but introduces an extra edge - see item 2).
--   2. Test if any vertex of either polygon lies inside the other
--      (point-in-polygon by ray casting).
--   3. Test if any pair of edges crosses (segment-segment intersection).
--
-- Steps 2 and 3 are pure SQL with arithmetic in plpgsql, so each row's
-- check costs ~2-10 microseconds.  At 100 000 rows that is ~57 seconds.
-- The synthetic river-closing in step 1 is also why Dan's returns 32 490
-- rows while PostGIS/S2 agree on 32 489: exactly one river has an
-- intersecting synthetic closing edge that GEOS does not see.
-- ============================================================================
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT count(*) AS rivers_in_west_us
  FROM rivers
 WHERE ST_Intersects(
         geom,
         ST_MakePolygon(
           ARRAY[-125.0, -100.0, -100.0, -125.0, -125.0],
           ARRAY[  30.0,   30.0,   50.0,   50.0,   30.0]));
