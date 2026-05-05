-- Q6_c_geohash.sql : 10 nearest POIs to Fort Collins, CO (KNN).
-- ============================================================================
-- KNN with c_geohash: a B-tree on a geohash int64 cell ID cannot traverse
-- in distance order (Z-order ≠ Euclidean order), so the canonical pattern
--
--     ORDER BY geom <-> point LIMIT 10
--
-- would Seq Scan + heapsort.  See Q6_c_geohash_seqscan.sql for that
-- foot-gun.  This file does the supported pattern instead:
--
--     1.  Pre-filter to a fixed-radius envelope (5 km) via the same
--         cgeo_spatial_candidates path Q1_c_geohash uses.
--     2.  Recheck distance with ST_DWithin (Vincenty) and ORDER BY.
--
-- The 5 km radius is sized to comfortably contain the 10 nearest POIs
-- on the 344k-row dataset (the same heuristic Q1_c_geohash uses).  An
-- expanding-ring helper analogous to S2's `spatial_knn` is left as
-- future work — see the README's "Open work" section.  The user
-- explicitly accepted both Seq Scan and ring expansion as KNN options
-- for c_geohash; this file is the radius-bounded variant, which gives
-- index-accelerated KNN for the dense case at the cost of needing a
-- per-call radius guess.
-- ============================================================================
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT md_pk,
       md_name,
       md_city,
       ST_Distance(geom::geography,
                   ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography,
                   true) AS dist_m
  FROM my_mapdata
 WHERE md_pk IN (
         SELECT cgeo_spatial_candidates(
           'my_mapdata',
           ST_MakeEnvelope(-105.0775 - 0.0590, 40.5853 - 0.0450,
                           -105.0775 + 0.0590, 40.5853 + 0.0450, 4326)))
   AND ST_DWithin(geom::geography,
                  ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography,
                  5000, true)
 ORDER BY dist_m
 LIMIT 10;
