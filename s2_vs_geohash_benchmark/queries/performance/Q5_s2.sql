-- operator_bbox_overlap_s2.sql
-- ============================================================================
-- THE BOUNDING BOX OVERLAP OPERATOR (&&)
-- 
-- The `yb_geospatial_s2` extension also natively supports the `&&` operator.
-- 
-- However, because YugabyteDB's LSM B-Tree cannot natively index bounding 
-- boxes, you must pass the envelope through `spatial_candidates` to generate 
-- the index range-scans (the BETWEEN and ANY(ancestors) scans) first.
--
-- Once you have the candidate rows, the `geom && envelope` check performs 
-- the exact GEOS-backed calculation.
-- ============================================================================

\timing on
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT count(*) 
FROM my_mapdata 
WHERE md_pk IN (
  SELECT spatial_candidates('my_mapdata', 
    ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326))
)
AND geom && ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326);
