-- Q4_dans.sql : rivers that intersect the western-US envelope (~5x CA area)
-- ============================================================================
-- UNDER THE HOOD
-- ----------------------------------------------------------------------------
-- This is where Dan's architecture breaks down.  His schema stores a single
-- geo_hash10 per row, which was populated from the row's one (lat, lon).
-- That works for a POI (one point = one geohash), but a river is a
-- LineString of 15 vertices spanning ~75 km - there is no single geohash
-- that represents it.  You would need a separate `(river_id, geohash)`
-- mapping table with a trigger, which Dan did not build.  The rivers
-- table in bench_dans has NO index by design.
--
-- Unlike Q1/Q2/Q3, Q4 has no "unrolled SQL" to show - the query is
-- already as low as it gets.  What changes is the execution plan and
-- the per-row work.
--
-- EXECUTION PLAN (from EXPLAIN, not SQL):
--
--     Seq Scan on rivers
--       Filter: ST_Intersects(geom, <polygon>)
--
-- Under the executor, this is a for-loop over every heap row:
--
--     for each row in rivers:
--         if ST_Intersects(row.geom, <polygon>):
--             accumulate into count(*)
--
-- PER-ROW WORK (what ST_Intersects actually does):
--
-- Dan's `geom` is a composite type `(lon double[], lat double[])`, so
-- ST_Intersects(geom, geom) in `25_GeometryFunctions.sql` reduces to:
--
--     ST_Intersects(p_a.lon[], p_a.lat[], p_b.lon[], p_b.lat[])
--
-- and that plpgsql function does:
--
--     1. For every vertex of A: point-in-polygon test against B
--        (ray-casting with array indexing)
--     2. For every vertex of B: point-in-polygon test against A
--     3. For every edge pair (A_i, A_{i+1}) vs (B_j, B_{j+1}):
--        segment-segment intersection test
--
--        The edge walk uses
--            CASE WHEN i = na THEN 1 ELSE i + 1 END
--        so when i reaches the last vertex, i+1 wraps to vertex 1.
--        For a LineString input this silently adds a synthetic closing
--        edge (last_vertex -> first_vertex) that does not exist in the
--        real geometry.  That is why Dan returns 32 490 while PostGIS
--        and S2 (both using GEOS, which does not close lines) return
--        32 489: exactly one river has its synthetic closing segment
--        clipping the western-US envelope.
--
-- All three steps are interpreted plpgsql with array-subscript arithmetic,
-- so each row's ST_Intersects call costs ~2-10 microseconds.  Times
-- 100 000 rows and 6 benchmark iterations = ~6 minutes of CPU on Q4
-- alone.  Per-iteration median lands around 57 seconds.
-- ============================================================================
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT count(*) AS rivers_in_west_us
  FROM rivers
 WHERE ST_Intersects(
         geom,
         ST_MakePolygon(
           ARRAY[-125.0, -100.0, -100.0, -125.0, -125.0],
           ARRAY[  30.0,   30.0,   50.0,   50.0,   30.0]));
