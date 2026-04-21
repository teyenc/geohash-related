-- Q1_postgis.sql : 10 nearest POIs within 5 km of Fort Collins, CO
-- PostGIS reference implementation using geography + GiST.
-- ============================================================================
-- UNDER THE HOOD
-- ----------------------------------------------------------------------------
-- ST_DWithin(geom::geography, pt::geography, 5000, true) expands into two
-- phases inside PostGIS's C code:
--
--   Phase 1  (index filter via the `&&` operator on geography):
--     PostGIS pads `pt` by 5000 m in every direction, forms a lat/lon
--     envelope, and asks the GiST index `ix_my_mapdata_geog_gist` for all
--     rows whose geography bounding box intersects that envelope.  GiST is
--     an R-tree over bounding boxes, stored as a local single-node B+tree
--     of MBRs - O(log N) probes, no network RTT.
--
--   Phase 2  (exact recheck):
--     For each surviving candidate PostGIS runs the real Vincenty geodesic
--     distance in C (geography_distance_cartesian + iterative inverse) and
--     keeps rows where dist <= 5000 m.  About 6 200 candidates enter this
--     phase for Q1; 5 052 pass, ~1 150 are rejected (they fell inside the
--     bbox but outside the actual circle).
--
-- The final `ORDER BY dist_m LIMIT 10` does a top-N heap sort over the
-- 5 052 surviving rows.  Total: one GiST scan + ~6 200 C distance calls.
-- ============================================================================
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT TEXT)
WITH anchor AS (
  SELECT ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326) AS pt
)
SELECT md_pk,
       md_name,
       md_city,
       ST_Distance(geom::geography, anchor.pt::geography, true) AS dist_m
  FROM my_mapdata, anchor
 WHERE ST_DWithin(geom::geography, anchor.pt::geography, 5000, true)
 ORDER BY dist_m
 LIMIT 10;
