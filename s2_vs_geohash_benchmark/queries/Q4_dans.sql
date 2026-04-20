-- Q4_dans.sql : rivers that intersect the California envelope
-- Dan's geohash index stores one geohash per row, which cannot cover a
-- multi-cell LineString.  With no usable index the query falls back to a
-- sequential scan that runs Dan's pure-SQL ST_Intersects on every row.
-- ----------------------------------------------------------------------------
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT count(*) AS rivers_in_ca
  FROM rivers
 WHERE ST_Intersects(
         geom,
         ST_MakePolygon(
           ARRAY[-124.4, -114.1, -114.1, -124.4, -124.4],
           ARRAY[ 32.5,   32.5,   42.0,   42.0,  32.5]));
