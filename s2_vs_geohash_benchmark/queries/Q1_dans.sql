-- Q1_dans.sql : 10 nearest POIs within 5 km of Fort Collins, CO
-- Dan's pure-SQL geohash extension.
-- ============================================================================
-- UNDER THE HOOD
-- ----------------------------------------------------------------------------
-- geohash_cells_for_bbox walks from the SW corner of the padded query bbox
-- east-then-north, emitting every precision-5 geohash cell that overlaps.
-- For this 5 km query the bbox is (-105.15, 40.52) -> (-105.00, 40.65) and
-- the walker returns exactly 16 text cells (each ~4.9 km x 4.9 km at lat 40):
--
--     9xjnx  9xjnz  9xjpp  9xjpr
--     9xjq8  9xjq9  9xjqb  9xjqc
--     9xjqf  9xjqg  9xjr0  9xjr1
--     9xjr2  9xjr3  9xjr4  9xjr6
--
-- The query unrolls to:
--
--     left(geo_hash10, 5) = ANY(ARRAY['9xjnx','9xjnz',...,'9xjr6']::text[])
--
-- Because `left(geo_hash10, 5)` is the indexed expression of
-- `ix_mapdata3 ON (left(geo_hash10, 5), md_name)` and the literal 5 is
-- constant-folded, the planner matches it to the functional index and
-- issues 16 separate B-tree probes (one per cell) yielding ~7 k candidates.
-- Phase 2 is Dan's pure-SQL ST_DWithin (Vincenty, in plpgsql) which keeps
-- 5 052 rows matching the 5 km circle exactly.
--
-- Why precision 5 is hardcoded: the PostgreSQL planner can only match a
-- functional index when the query uses the exact same expression with a
-- constant-folded literal. `left(geo_hash10, (SELECT ...)) = ANY(...)`
-- cannot be matched and degrades to a Seq Scan.
-- ============================================================================
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
