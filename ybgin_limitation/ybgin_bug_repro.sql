-- ybgin_bug_repro.sql
-- ============================================================================
-- Minimal reproducer for YugabyteDB's `ybgin` multi-key scan limitation.
-- ----------------------------------------------------------------------------
-- The table and column names here match the terminology you'd use for real
-- spatial data:
--     object   = one indexed geometry (a point, line, or polygon)
--     cell_ids = the array of S2 cell IDs that cover that geometry
--
-- A spatial query computes an array of S2 cells covering the query envelope,
-- then asks: "which objects' cell_ids overlap ANY of those query cells?"
-- That question is literally:
--     cell_ids && ARRAY[<query cells>]
-- which is CASE 2 below -- exactly the query shape that `ybgin` rejects.
--
-- Run this in any YB database (ysqlsh).  Expected behavior:
--   CASE 1  -> works (single-cell lookup)
--   CASE 2  -> ERRORS with `ybgin index method cannot use more than one
--              required scan entry`.
--
-- Source of the guard: yugabyte-db/src/postgres/src/backend/access/ybgin/
--                      ybginget.c:408-414
-- ============================================================================

DROP TABLE IF EXISTS objects;

CREATE TABLE objects (
  object_id int    PRIMARY KEY,
  cell_ids  int8[]                  -- S2-style cell IDs that cover this object
);

-- Three "objects" with overlapping cell coverings (pretend these are S2 IDs).
INSERT INTO objects VALUES
  (1, ARRAY[8520148959::int8, 8520148960]),
  (2, ARRAY[8520148960::int8, 8520148961]),
  (3, ARRAY[8520148961::int8, 8520148962]);

CREATE INDEX objects_cell_idx ON objects USING ybgin (cell_ids);

-- ----------------------------------------------------------------------------
-- CASE 1: Single-cell lookup.  Works fine.
-- ----------------------------------------------------------------------------
\echo ''
\echo '-- CASE 1: Single cell (works)'
SELECT object_id FROM objects
 WHERE cell_ids @> ARRAY[8520148959::int8];

-- ----------------------------------------------------------------------------
-- CASE 2: Multi-cell OR via &&.  This is the exact shape of a real spatial
-- query: "find objects whose cells overlap ANY of the query's N cells."
-- The planner marks each query cell as a separate required scan entry, so
-- `nrequired = 3`, and ybgin rejects the scan.
-- ----------------------------------------------------------------------------
\echo ''
\echo '-- CASE 2: Multi-cell OR via && (BUG: crashes)'
SELECT object_id FROM objects
 WHERE cell_ids && ARRAY[8520148959::int8, 8520148960, 8520148961];

-- Expected error:
--   ERROR:  unsupported ybgin index scan
--   DETAIL:  ybgin index method cannot use more than one required scan entry: got 3.

DROP TABLE objects;
