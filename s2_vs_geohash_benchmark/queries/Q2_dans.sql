-- Q2_dans.sql : COUNT of POIs within 10 km of Fort Collins, CO
-- Uses geohash_cells_for_bbox to walk the full 20 km x 20 km padded bbox.
-- At precision 5 (~3.7 km x 4.9 km cells at lat 40.5) the walker emits
-- roughly 30 cells.  Uses ix_mapdata3 on left(geo_hash10, 5).
-- ----------------------------------------------------------------------------
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
WITH nearby_cells AS (
  SELECT * FROM geohash_cells_for_bbox(
    -105.20, 40.47,       -- SW corner of 10 km-padded bbox
    -104.95, 40.70,       -- NE corner of 10 km-padded bbox
    5                     -- precision 5 -> ~3.7 km x 4.9 km cells
  ) h
)
SELECT count(*) AS hits
  FROM my_mapdata
 WHERE left(geo_hash10, 5) = ANY(ARRAY(SELECT h FROM nearby_cells))
   AND ST_DWithin(geom::geography,
                  ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography,
                  10000, true);
