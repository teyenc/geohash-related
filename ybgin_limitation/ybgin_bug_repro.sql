-- ybgin_bug_repro.sql
-- ============================================================================
-- Minimal reproducer for YugabyteDB's `ybgin` multi-key OR scan limitation
-- ----------------------------------------------------------------------------
-- Run this in any YB database (ysqlsh).  Expected behavior:
--   CASE 1 -> works (single-key lookup: the only case ybgin supports)
--   CASE 2 -> ERRORS with `ybgin index method cannot use more than one
--             required scan entry`.
--
-- Source of the guard: yugabyte-db/src/postgres/src/backend/access/ybgin/
--                      ybginget.c:408-414
-- ============================================================================

DROP TABLE IF EXISTS ybgin_bug_demo;

CREATE TABLE ybgin_bug_demo (
  id    int   PRIMARY KEY,
  tags  text[]
);

INSERT INTO ybgin_bug_demo VALUES
  (1, ARRAY['alpha',   'bravo']),
  (2, ARRAY['bravo',   'charlie']),
  (3, ARRAY['charlie', 'delta']),
  (4, ARRAY['delta',   'echo']);

CREATE INDEX ybgin_bug_idx ON ybgin_bug_demo USING ybgin (tags);

-- ----------------------------------------------------------------------------
-- CASE 1: Single-key containment. Works.  This is the only pattern ybgin
-- executes today.
-- ----------------------------------------------------------------------------
\echo ''
\echo '-- CASE 1: Single-key (works)'
SELECT id FROM ybgin_bug_demo WHERE tags @> ARRAY['alpha'];

-- ----------------------------------------------------------------------------
-- CASE 2: OR across multiple keys via `&&`.  This is the bug.
--
-- The `&&` operator means "any of these keys overlap".  The planner marks
-- each of the N keys as a separate required entry, so `nrequired == 3`.
-- `ybginSetupBinds()` rejects anything where `nrequired != 1`.
--
-- `&&` is EXACTLY the query shape that a spatial index needs
-- (`s2_cell = ANY (ARRAY[<covering_cells>])`), which is why we could NOT
-- build the S2 spatial extension on top of ybgin.
-- ----------------------------------------------------------------------------
\echo ''
\echo '-- CASE 2: OR via && (BUG: crashes)'
SELECT id FROM ybgin_bug_demo WHERE tags && ARRAY['alpha', 'bravo', 'charlie'];

-- Expected error:
--   ERROR:  unsupported ybgin index scan
--   DETAIL:  ybgin index method cannot use more than one required scan entry: got 3.

DROP TABLE ybgin_bug_demo;
