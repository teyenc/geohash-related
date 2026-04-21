-- Q4_postgis.sql : rivers that intersect the western-US envelope (~5x CA area)
-- ============================================================================
-- UNDER THE HOOD
-- ----------------------------------------------------------------------------
-- Rivers are LineStrings (15 vertices, ~75 km end-to-end).  PostGIS builds
-- a GiST index over each river's bounding rectangle (`ix_rivers_geom_gist`):
--
--   Phase 1  (GiST MBR test via `&&`):
--     Returns every river whose bbox overlaps the western-US envelope.
--     For a 25 deg x 20 deg envelope, the bbox test is already very
--     selective against the 100 000-row table - on a rectangular query
--     the MBR test and the exact test almost agree.
--
--   Phase 2  (exact ST_Intersects in GEOS C):
--     For each candidate river, GEOS tests whether any river edge crosses
--     the envelope or whether any river vertex falls inside it.  On a
--     rectangular envelope this is nearly free, and the recheck drops
--     very few rows - 32 489 rivers pass in total.
--
-- Plan: Bitmap Index Scan (ix_rivers_geom_gist) -> Bitmap Heap Scan with
-- the ST_Intersects recheck as a filter.  Single-node, no RPC cost, runs
-- in ~70-150 ms on a warm cache.
-- ============================================================================
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT TEXT)
SELECT count(*) AS rivers_in_west_us
  FROM rivers
 WHERE ST_Intersects(
         geom,
         ST_MakeEnvelope(-125.0, 30.0, -100.0, 50.0, 4326));
