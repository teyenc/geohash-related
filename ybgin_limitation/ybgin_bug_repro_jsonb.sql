-- ybgin_bug_repro_jsonb.sql
-- ============================================================================
-- Alternate reproducer using `jsonb ?|` (any-key-exists).  This operator
-- shape is the closest analogy to what a spatial index does internally:
-- "find rows whose indexed set of keys overlaps ANY of these N query keys."
-- That's why spatial queries trigger the same crash.
-- ============================================================================

DROP TABLE IF EXISTS jsonb_bug_demo;

CREATE TABLE jsonb_bug_demo (
  id    int   PRIMARY KEY,
  data  jsonb
);

INSERT INTO jsonb_bug_demo VALUES
  (1, '{"type": "cafe", "tags": ["coffee", "wifi"]}'),
  (2, '{"type": "bar",  "tags": ["beer",   "wifi"]}'),
  (3, '{"type": "cafe", "tags": ["tea",    "quiet"]}');

CREATE INDEX jsonb_bug_idx ON jsonb_bug_demo USING ybgin (data);

-- ----------------------------------------------------------------------------
-- Single-key ?| : works.
-- ----------------------------------------------------------------------------
\echo ''
\echo '-- Single-key ?| (works)'
SELECT id FROM jsonb_bug_demo WHERE data ?| ARRAY['type'];

-- ----------------------------------------------------------------------------
-- Multi-key ?| : CRASHES with nrequired != 1.
-- ----------------------------------------------------------------------------
\echo ''
\echo '-- Multi-key ?| (BUG: crashes)'
SELECT id FROM jsonb_bug_demo WHERE data ?| ARRAY['type', 'tags', 'foo'];

-- Expected error:
--   ERROR:  unsupported ybgin index scan
--   DETAIL:  ybgin index method cannot use more than one required scan entry: got 3.

DROP TABLE jsonb_bug_demo;
