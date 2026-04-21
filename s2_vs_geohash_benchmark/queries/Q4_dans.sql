-- Q4_dans.sql : rivers that intersect the western-US envelope (~5x CA area)
-- Dan's geohash index stores one geohash per row, which cannot cover a
-- multi-cell LineString.  With no usable index the query falls back to a
-- sequential scan that runs Dan's pure-SQL ST_Intersects on every row.
-- Scaling the envelope up does not change the plan - Dan's still seq scans
-- all 5000 rivers.
-- ----------------------------------------------------------------------------
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT count(*) AS rivers_in_west_us
  FROM rivers
 WHERE ST_Intersects(
         geom,
         ST_MakePolygon(
           ARRAY[-125.0, -100.0, -100.0, -125.0, -125.0],
           ARRAY[  30.0,   30.0,   50.0,   50.0,   30.0]));
