-- Q2_postgis.sql : COUNT of POIs within 50 km of Fort Collins, CO
-- ============================================================================
-- IDENTICAL SQL TO Q2_s2.sql.  Anchor point is inlined (no CTE) for the
-- same reason as Q1: YB's planner cannot push a hashed-SubPlan reference
-- down to drive an Index Scan, so on bench_s2 the CTE form falls back to
-- a Seq Scan with a SubPlan filter.  Inlining the point gives a clean
-- Index Scan via the planner hook on S2 and is no worse on PostGIS.
-- ============================================================================
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT TEXT)
SELECT count(*) AS hits
  FROM my_mapdata
 WHERE ST_DWithin(geom::geography,
                  ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography,
                  50000, true);
