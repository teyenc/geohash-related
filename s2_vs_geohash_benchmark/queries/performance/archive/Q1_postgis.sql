-- Q1_postgis.sql : 10 nearest POIs within 5 km of Fort Collins, CO
-- PostGIS reference implementation using geography + GiST.
-- ============================================================================
-- This file uses the EXACT SAME SQL as Q1_s2.sql so the demo can paste one
-- query into both engines.  We inline the anchor point instead of using a
-- CTE because YB's planner cannot push a hashed SubPlan reference down
-- into an Index Scan -- the CTE form would force a Seq Scan on bench_s2.
--
-- UNDER THE HOOD (PostGIS):
--   Phase 1 (GiST bbox filter via `&&` on geography): the planner pads
--   the anchor point by 5000 m, asks ix_my_mapdata_geog_gist for every
--   row whose geography MBR intersects that envelope.
--   Phase 2 (Vincenty recheck): for each candidate, the real geodesic
--   distance is computed in C; rows with dist > 5000 m are dropped.
-- ============================================================================
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT TEXT)
SELECT md_pk,
       md_name,
       md_city,
       ST_Distance(geom::geography,
                   ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography,
                   true) AS dist_m
  FROM my_mapdata
 WHERE ST_DWithin(geom::geography,
                  ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography,
                  5000, true)
 ORDER BY dist_m
 LIMIT 10;
