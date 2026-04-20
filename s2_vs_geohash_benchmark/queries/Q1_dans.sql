-- Q1_dans.sql : 10 nearest POIs within 1 km of Fort Collins, CO
-- Dan's correct geohash pattern: geohash_cells_for_bbox walks from the SW
-- corner of the padded query bbox east-then-north until the NE corner is
-- covered, returning every precision-6 cell that touches the bbox.
--
-- 1 km radius @ lat 40.5 -> ~0.012 deg lon, 0.009 deg lat.
-- Padded bbox is (-105.0892, 40.5763) -> (-105.0658, 40.5943), about 2 km x 2 km.
-- At precision 6 (~0.93 km x 0.61 km per cell at this lat) the walker returns
-- roughly 12 cells - enough to cover the whole 1 km circle.
-- Uses ix_mapdata4 on left(geo_hash10, 6).
-- ----------------------------------------------------------------------------
-- Why precision 6 is a hardcoded LITERAL (not a variable or subquery):
--
-- Dan ships three functional indexes with the precision baked into each:
--   ix_mapdata3          ON (left(geo_hash10, 5), md_name)
--   ix_mapdata4          ON (left(geo_hash10, 6), md_name)
--   ix_mapdata_geo_hash8 ON (geo_hash8)
--
-- PostgreSQL's planner can only match an expression index when the query
-- predicate uses the exact same expression with a constant-folded literal.
-- So `left(geo_hash10, 6) = ANY(...)` hits ix_mapdata4 and runs as an index
-- scan; `left(geo_hash10, (SELECT length(...) FROM ...)) = ANY(...)`
-- degrades to a Seq Scan because the planner can't prove the subquery
-- resolves to 6 at plan time.  Measured: 106 ms -> 824 ms for this Q1.
--
-- Dan DOES have a `geohash_cells_for_bbox(lon1,lat1,lon2,lat2)` overload
-- (no precision arg) that auto-picks 5/6/8 from the bbox span, but the
-- caller still has to name the matching `left(geo_hash10, N)` expression
-- in its own WHERE clause, so the auto-picker alone doesn't get us off
-- the hardcoding hook.
--
-- The idiomatic fix (not shipped in Dan's demo) is a plpgsql wrapper that
-- uses EXECUTE format(...) to splice the right literal into the generated
-- SQL at runtime, letting the functional index still match:
--
--   CREATE FUNCTION geohash_candidates(lon1 float, lat1 float,
--                                      lon2 float, lat2 float)
--   RETURNS SETOF bigint LANGUAGE plpgsql AS $$
--   DECLARE
--     cells text[];
--     prec  int;
--   BEGIN
--     SELECT array_agg(h), max(length(h))
--       INTO cells, prec
--       FROM geohash_cells_for_bbox(lon1, lat1, lon2, lat2) h;
--
--     IF prec = 8 THEN
--       RETURN QUERY EXECUTE
--         'SELECT md_pk FROM my_mapdata WHERE geo_hash8 = ANY($1)'
--         USING cells;
--     ELSE
--       RETURN QUERY EXECUTE format(
--         'SELECT md_pk FROM my_mapdata WHERE left(geo_hash10, %s) = ANY($1)',
--         prec
--       ) USING cells;
--     END IF;
--   END;
--   $$;
--
-- With that wrapper, the call site becomes as clean as our S2 version:
--
--   WHERE md_pk IN (SELECT geohash_candidates(
--                     -105.0892, 40.5763, -105.0658, 40.5943))
--     AND ST_DWithin(geom::geography, pt::geography, 1000, true)
--
-- We keep the precision literal hardcoded here because (a) that's the
-- idiom Dan's demo actually ships with, and (b) it keeps the generated
-- plan auditable in EXPLAIN output without dynamic SQL indirection.
-- ----------------------------------------------------------------------------
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
WITH nearby_cells AS (
  SELECT * FROM geohash_cells_for_bbox(
    -105.0892, 40.5763,   -- SW corner of 1 km-padded bbox
    -105.0658, 40.5943,   -- NE corner of 1 km-padded bbox
    6                     -- precision 6 -> ~0.93 km x 0.61 km cells
  ) h
)
SELECT md_pk,
       md_name,
       md_city,
       ST_Distance(geom::geography,
                   ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography,
                   true) AS dist_m
  FROM my_mapdata
 WHERE left(geo_hash10, 6) = ANY(ARRAY(SELECT h FROM nearby_cells))
   AND ST_DWithin(geom::geography,
                  ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography,
                  1000, true)
 ORDER BY dist_m
 LIMIT 10;
