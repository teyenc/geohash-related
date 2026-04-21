-- Q1_s2.sql : 10 nearest POIs within 5 km of Fort Collins, CO
-- yb_geospatial_s2 extension: S2 mapping table + GEOS exact recheck.
-- ============================================================================
-- UNDER THE HOOD
-- ----------------------------------------------------------------------------
-- spatial_candidates('my_mapdata', envelope) internally does:
--
--   1)  query_cells = ST_S2Covering(envelope, min_level=10, max_level=20)
--       For this 5 km envelope S2RegionCoverer returns exactly 9 cells
--       as int8.  A representative few (Hilbert-ordered):
--
--           -8689355731918389248
--           -8689353532895133696
--           -8689333741685833728
--           -8689331542662578176
--           -8689329343639322624
--           -8687807619546480640   -- notice the jump:  S2 wraps around
--           -8687783705168576512   -- face edges and returns multi-face
--                                    coverings transparently.
--
--   2)  For each of the 9 cells, emit two separate SELECTs (UNION ALL):
--
--       a. Descendant search:
--              SELECT id FROM my_mapdata_s2_index
--               WHERE s2_cell BETWEEN (cell - (lsb(cell) - 1))
--                                 AND (cell + (lsb(cell) - 1));
--
--          This is a tight range scan on the range-sharded primary key
--          `(s2_cell ASC, id)`.  Because S2 IDs are a Hilbert-ordered
--          contiguous interval for any subtree, this single BETWEEN
--          catches every indexed descendant cell.
--
--       b. Ancestor search:
--              SELECT id FROM my_mapdata_s2_index
--               WHERE s2_cell = ANY(ARRAY[parent_ids]);
--
--          Walks up the S2 tree from the query cell until level 4
--          (~600 km cells), producing one ID per level along the way -
--          6 ancestors for a level-10 covering cell, up to 16 for a
--          level-20 one.  These are short point probes on the same B-tree.
--          See Q2_s2.sql / Q3_s2.sql for a concrete example of the
--          ancestor array and computed BETWEEN range.
--
--       UNION ALL (not OR) because YB has no BitmapOr executor: a single
--       OR predicate would force a Seq Scan.
--
--   Net: 9 BETWEEN range scans + 9 ANY(array) probes against
--   my_mapdata_s2_index, yielding ~8 357 candidate md_pks.
--
-- Phase 2 is the exact ST_DistanceSphere(geom, POINT) <= 5000 filter,
-- implemented by our C `st_distance_sphere` -> 5 052 rows pass,
-- top-N heap sort picks the nearest 10.
-- ============================================================================
EXPLAIN (ANALYZE, VERBOSE, DIST, DEBUG)
SELECT md_pk,
       md_name,
       md_city,
       ST_DistanceSphere(geom,
                         ST_GeomFromText('POINT(-105.0775 40.5853)', 4326)) AS dist_m
  FROM my_mapdata
 WHERE md_pk IN (
         SELECT spatial_candidates(
           'my_mapdata',
           ST_MakeEnvelope(-105.15, 40.52, -105.00, 40.65, 4326))
       )
   AND ST_DistanceSphere(geom,
                         ST_GeomFromText('POINT(-105.0775 40.5853)', 4326)) <= 5000
 ORDER BY dist_m
 LIMIT 10;
