-- Q2_dans.sql : COUNT of POIs within 50 km of Fort Collins, CO
-- Uses geohash_cells_for_bbox to walk the full ~130 km x ~100 km padded bbox.
-- At precision 5 (~4.9 km x 4.9 km cells at lat 40.5) the walker emits
-- roughly 620 cells.  Uses ix_mapdata3 on left(geo_hash10, 5).
-- ----------------------------------------------------------------------------
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
