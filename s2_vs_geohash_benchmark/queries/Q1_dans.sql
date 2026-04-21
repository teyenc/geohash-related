-- Q1_dans.sql : 10 nearest POIs within 5 km of Fort Collins, CO
-- Dan's correct geohash pattern: geohash_cells_for_bbox walks from the SW
-- corner of the padded query bbox east-then-north until the NE corner is
-- covered, returning every precision-5 cell that touches the bbox.
--
-- 5 km radius @ lat 40.5 -> ~0.059 deg lon, 0.045 deg lat.
-- Padded bbox is (-105.15, 40.52) -> (-105.00, 40.65), about 13 km x 14 km.
-- At precision 5 (~4.9 km x 4.9 km per cell at this lat) the walker returns
-- roughly 12 cells.  Uses ix_mapdata3 on left(geo_hash10, 5).
-- ----------------------------------------------------------------------------
-- Why precision 5 is a hardcoded LITERAL (not a variable or subquery):
-- PostgreSQL's planner can only match a functional index when the predicate
-- uses the exact same expression with a constant-folded literal. So
-- `left(geo_hash10, 5) = ANY(...)` hits ix_mapdata3 and runs as an Index
-- Scan; `left(geo_hash10, (SELECT ...)) = ANY(...)` degrades to a Seq Scan.
-- See README for the plpgsql-wrapper idiom that lifts this constraint.
-- ----------------------------------------------------------------------------
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
WITH nearby_cells AS (
  SELECT * FROM geohash_cells_for_bbox(
    -105.15, 40.52,       -- SW corner of 5 km-padded bbox
    -105.00, 40.65,       -- NE corner of 5 km-padded bbox
    5                     -- precision 5 -> ~4.9 km x 4.9 km cells
  ) h
)
SELECT md_pk,
       md_name,
       md_city,
       ST_Distance(geom::geography,
                   ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography,
                   true) AS dist_m
  FROM my_mapdata
 WHERE left(geo_hash10, 5) = ANY(ARRAY(SELECT h FROM nearby_cells))
   AND ST_DWithin(geom::geography,
                  ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography,
                  5000, true)
 ORDER BY dist_m
 LIMIT 10;
