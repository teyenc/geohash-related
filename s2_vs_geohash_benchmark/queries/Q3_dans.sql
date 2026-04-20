-- Q3_dans.sql : COUNT of POIs inside Denver metro rectangle
-- Uses Dan's geohash_cells_for_bbox() which auto-picks precision and
-- generates all covering geohash cells for the box (40-km box -> precision 5).
-- ----------------------------------------------------------------------------
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
WITH covering AS (
  SELECT * FROM geohash_cells_for_bbox(-105.20, 39.60, -104.70, 40.00) h
)
SELECT count(*) AS hits
  FROM my_mapdata
 WHERE left(geo_hash10, 5) = ANY(ARRAY(SELECT h FROM covering))
   AND ST_Intersects(
         geom,
         ST_MakePolygon(
           ARRAY[-105.20, -104.70, -104.70, -105.20, -105.20],
           ARRAY[ 39.60,  39.60,  40.00,  40.00,  39.60 ]));
