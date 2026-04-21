-- Q2_postgis.sql : COUNT of POIs within 50 km of Fort Collins, CO
-- ============================================================================
-- UNDER THE HOOD
-- ----------------------------------------------------------------------------
-- Same two-phase plan as Q1, just a larger circle:
--
--   Phase 1  (GiST bbox filter):
--     ix_my_mapdata_geog_gist returns every row whose geography bounding box
--     intersects the 50 km-padded envelope around Fort Collins (~1.2 deg
--     lon x 1 deg lat).  On a local single-node PG this is a Parallel
--     Bitmap Heap Scan over the GiST index.
--
--   Phase 2  (Vincenty recheck):
--     PostGIS computes the real spherical distance in C for each candidate
--     and keeps rows where dist <= 50 000 m.
--
-- The `count(*)` aggregate consumes the filtered stream - no sort, no limit.
-- The result is the ground-truth count our S2 extension is measured against.
-- ============================================================================
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT TEXT)
WITH anchor AS (
  SELECT ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326) AS pt
)
SELECT count(*) AS hits
  FROM my_mapdata, anchor
 WHERE ST_DWithin(geom::geography, anchor.pt::geography, 50000, true);
