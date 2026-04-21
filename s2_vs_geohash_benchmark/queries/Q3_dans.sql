-- Q3_dans.sql : COUNT of POIs inside a 2.5 deg x 2.0 deg (~200 km x ~200 km)
-- Colorado Front Range box.
--
-- Precision 5 is the coarsest geohash index Dan ships (ix_mapdata3 on
-- left(geo_hash10, 5)).  At this bbox size the walker emits roughly 2600
-- cells; the 4-arg auto-picker would also land on precision 5, but we pass
-- it explicitly for clarity.
-- ----------------------------------------------------------------------------
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
WITH covering AS (
  SELECT * FROM geohash_cells_for_bbox(-106.20, 38.80, -103.70, 40.80, 5) h
)
SELECT count(*) AS hits
  FROM my_mapdata
 WHERE left(geo_hash10, 5) = ANY(ARRAY(SELECT h FROM covering))
   AND ST_Intersects(
         geom,
         ST_MakePolygon(
           ARRAY[-106.20, -103.70, -103.70, -106.20, -106.20],
           ARRAY[  38.80,   38.80,   40.80,   40.80,   38.80]));
