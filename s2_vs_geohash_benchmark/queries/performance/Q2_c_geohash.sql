-- Q2_c_geohash.sql : COUNT of POIs within 50 km of Fort Collins, CO
-- ============================================================================
-- Same shape as Q2_s2.sql but the candidate-cell injection is explicit
-- (c_geohash has no planner hook). The ST_DWithin recheck handles the
-- exact 50 km circle; the cgeo_spatial_candidates pre-filter restricts
-- candidates to the ~50 km lat/lon-padded bbox cover.
--
-- Expected hit count: 25 311 (matches the bench_s2 Q2 hit count exactly,
-- because both engines use the same WGS84 spheroid recheck via
-- yb_geospatial_s2's GEOS path; PostGIS's Vincenty differs by ~26 rows on
-- the boundary — see README).
-- ============================================================================
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT count(*) AS hits
  FROM my_mapdata
 WHERE md_pk IN (
         SELECT cgeo_spatial_candidates(
           'my_mapdata',
           -- 50 km padding: ~0.45 deg lat, ~0.59 deg lon at lat 40.5.
           ST_MakeEnvelope(-105.0775 - 0.59, 40.5853 - 0.45,
                           -105.0775 + 0.59, 40.5853 + 0.45, 4326)))
   AND ST_DWithin(geom::geography,
                  ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography,
                  50000, true);
