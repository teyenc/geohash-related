-- Q3_dans.sql : COUNT of POIs inside a 2.5 deg x 2.0 deg (~200 km x ~200 km)
-- Colorado Front Range box.
-- ============================================================================
-- UNDER THE HOOD
-- ----------------------------------------------------------------------------
-- This is the scaling stress test for Dan's geohash approach.  At
-- precision 5 (the coarsest grid Dan ships - ix_mapdata3), a 2.5 deg x
-- 2.0 deg box needs 2 726 cells to cover.  First/last few:
--
--     9wukx  9wukz  9wump  9wumr  9wumx  9wumz  ...
--                                          ...  9xq05  9xq0h  9xq0j
--                                               9xq0n  9xq0p  9xq20
--
-- The query passes a 2 726-element text array into:
--
--     left(geo_hash10, 5) = ANY(ARRAY[<2726 geohashes>]::text[])
--
-- ix_mapdata3 still matches the expression, but now the planner has 2 726
-- B-tree probes to do.  In YB each probe is a tablet RPC (unless the
-- Batched Nested Loop Join packs them into a batch, ~1 000/batch by
-- default), so this collapses into ~3 distributed round-trips fetching
-- ~191 k candidate rows in total.
--
-- Phase 2 is Dan's pure-SQL ST_Intersects(point, polygon) - a point-in-
-- polygon test in plpgsql.  For a rectangle that simplifies to four
-- inequality checks per row, but still interpreted plpgsql, executed
-- ~191 k times.  190 060 rows pass the exact polygon test, matching
-- PostGIS.
--
-- Notice Dan's cells grew from 644 (Q2, 50 km) to 2 726 (Q3, ~200 km box)
-- as the area grew ~10x.  S2 grew only 53 -> 130 for the same scale jump,
-- because its coverer adapts cell *size* while Dan's precision is pinned.
-- ============================================================================
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
