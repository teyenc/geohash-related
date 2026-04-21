-- Q2_dans.sql : COUNT of POIs within 50 km of Fort Collins, CO
-- ============================================================================
-- UNDER THE HOOD
-- ----------------------------------------------------------------------------
-- The 50 km-padded bbox is (-105.68, 40.08) -> (-104.48, 41.08), about
-- 130 km x 110 km.  geohash_cells_for_bbox(lon_min, lat_min, lon_max, lat_max, 5)
-- walks the grid and emits 644 precision-5 cells.  First and last few:
--
--     9xhu5  9xhu7  9xhue  9xhug  9xhuh  9xhuj  ...
--                                          ...  9xm9m  9xm9n  9xm9q
--                                               9xm9s  9xm9t  9xm9w
--
-- This becomes a 644-element `text[]` passed into:
--
--     left(geo_hash10, 5) = ANY(ARRAY['9xhu5', ..., '9xm9w']::text[])
--
-- ix_mapdata3 on `(left(geo_hash10, 5), md_name)` matches the expression,
-- so the planner rewrites this as 644 separate B-tree probes.  Each probe
-- returns the rows whose first-5-char geohash equals that cell.  In YB these
-- probes run as part of a Batched Nested Loop Join that packs ~1 000 keys
-- per batch into a single DocDB round-trip, so the 644 probes finish in
-- ~1-2 RPCs to each tablet.
--
-- Phase 2 is Dan's plpgsql ST_DWithin (Vincenty) on every candidate;
-- 25 337 rows pass the exact 50 km circle, matching PostGIS.  Notice that
-- the number of geohash cells grew 40x vs Q1 (16 -> 644) because
-- precision 5 is a fixed cell size and the radius scaled 10x.  S2, by
-- contrast, adapts cell size automatically and stays at ~53 cells.
-- ============================================================================
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
WITH nearby_cells AS (
  SELECT * FROM geohash_cells_for_bbox(
    -105.68, 40.08,       -- SW corner of 50 km-padded bbox
    -104.48, 41.08,       -- NE corner of 50 km-padded bbox
    5                     -- precision 5 -> ~4.9 km x 4.9 km cells
  ) h
)
SELECT count(*) AS hits
  FROM my_mapdata
 WHERE left(geo_hash10, 5) = ANY(ARRAY(SELECT h FROM nearby_cells))
   AND ST_DWithin(geom::geography,
                  ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography,
                  50000, true);
