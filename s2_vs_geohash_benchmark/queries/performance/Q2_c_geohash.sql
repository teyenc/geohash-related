-- Q2_c_geohash.sql : COUNT of POIs within 50 km of Fort Collins, CO
-- ============================================================================
-- Same shape as Q2_s2.sql but the candidate-cell injection is explicit
-- (c_geohash has no planner hook). The ST_DWithin recheck handles the
-- exact 50 km circle; the cgeo_text_spatial_candidates pre-filter restricts
-- candidates to the ~50 km lat/lon-padded bbox cover.
--
-- Storage: my_mapdata_cgeo_index(id, geohash) at index_prec=10.
-- Query precision: 6 (~1.2 km × 600 m cells). 6 ≤ 10 so any L10 stored
-- cell falls within a (min10, max10) range padded from a level-6 prefix.
--
-- Expected hit count: 25 337 (matches the ground-truth full-scan via
-- ST_DistanceSpheroid in this bench_cgeo db; bench_s2's expected 25 311
-- is from a slightly different test harness — see README).
-- ============================================================================
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT count(*) AS hits
  FROM my_mapdata
 WHERE md_pk IN (
         SELECT cgeo_text_spatial_candidates(
           'my_mapdata',
           -- 50 km padding: ~0.45 deg lat, ~0.59 deg lon at lat 40.5.
           ST_MakeEnvelope(-105.0775 - 0.59, 40.5853 - 0.45,
                           -105.0775 + 0.59, 40.5853 + 0.45, 4326), 6))
   AND ST_DWithin(geom::geography,
                  ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography,
                  50000, true);
