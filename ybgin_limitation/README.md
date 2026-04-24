# The `ybgin` multi-key OR scan limitation

This folder documents a limitation in YugabyteDB's `ybgin` index that directly shaped the architecture of our `yb_geospatial_s2` extension. A spatial query's natural shape — "find rows matching ANY of these N cells" — is exactly the shape that `ybgin` rejects today. This doc shows the bug, gives you a 10-second reproducer, cites the source, and explains the consequence for spatial indexing.

## TL;DR

```sql
CREATE TABLE objects (object_id int PRIMARY KEY, cell_ids int8[]);
CREATE INDEX ON objects USING ybgin (cell_ids);

SELECT object_id FROM objects WHERE cell_ids @> ARRAY[100::int8];                 -- ✅ works (single cell)
SELECT object_id FROM objects WHERE cell_ids && ARRAY[100::int8, 200, 300];       -- ❌ ERROR (multi-cell OR)
--     ERROR:  unsupported ybgin index scan
--     DETAIL:  ybgin index method cannot use more than one required
--              scan entry: got 3.
```

**Terminology map (toy → real):**

| Toy reproducer | Real spatial use case |
|---|---|
| `object_id` | Any primary key of an indexed geometry (a point, line, or polygon row) |
| `cell_ids int8[]` | The array of S2 cell IDs that cover that geometry |
| `ARRAY[100, 200, 300]` in the query | The S2 cells covering the query envelope |
| `cell_ids && ARRAY[…]` | "Does this object's cells overlap ANY query cell?" — the natural spatial filter |

The `&&` operator is "overlaps ANY of these keys" — the exact semantics a spatial index needs. That OR semantic is what triggers the crash. (Note: `@>` with multiple elements also uses the index without crashing, but `@>` means "contains ALL" — wrong semantics for spatial queries. See "Why `@>` is not the workaround" below.)

## How this maps to the real spatial use case

The reproducer's `objects` table and `cell_ids int8[]` column are exactly the shape a CockroachDB-style spatial index would store per row. There is no rename or reinterpretation — the toy data is already the right type.

### Concrete example

If we had built the GIN approach, the table would look like:

```sql
CREATE TABLE shapes (
  object_id int PRIMARY KEY,
  name      text,
  geom      geometry,
  cell_ids  int8[]       -- one entry per S2 cell that covers `geom`
);
CREATE INDEX ON shapes USING ybgin (cell_ids);
```

Inserting California's state polygon:

```sql
INSERT INTO shapes VALUES (
  1,
  'California',
  ST_GeomFromText('POLYGON(...)'),
  ARRAY[1001::int8, 1002, 1003, 1004, 1005, 1006, 1007, 1008]  -- the 8-cell S2 covering
);
```

A user asks "find shapes overlapping the Bay Area." The extension computes the Bay Area's S2 covering, say 4 cells `[2001, 2002, 2003, 2004]`, and runs:

```sql
SELECT object_id FROM shapes
 WHERE cell_ids && ARRAY[2001::int8, 2002, 2003, 2004];
--            ↑        ↑
--   object's cells    query cells
```

This is structurally identical to CASE 2 in the reproducer (`cell_ids && ARRAY[100, 200, 300]`). It asks: "does this object's cell list have ANY cell in common with the query's cell list?" A yes-answer means the two geometries' S2 coverings overlap, which is the filter we want before the exact GEOS recheck.

**And this is exactly the query shape that `ybgin` crashes on.** With N query cells, `nrequired = N`, and the `nrequired != 1` guard rejects it. That's why we had to abandon the GIN-based approach and build `yb_geospatial_s2` on a B-tree mapping table instead.

## Contents of this folder

| File | What it is |
|---|---|
| `README.md` | This document |
| `ybgin_bug_repro.sql` | Minimal `int8[]` reproducer with `object_id` / `cell_ids` column names, one-to-one with real spatial data |
| `ybgin_bug_repro_jsonb.sql` | Alternate reproducer using `jsonb ?\|`, closest analogy to a spatial query |
| `run_ybgin_bug_repro.sh` | Wrapper that runs both against a live YB cluster |

## How to reproduce

### Option A — one-shot

```bash
cd geohash-related/ybgin_limitation
./run_ybgin_bug_repro.sh
```

This runs both reproducers end-to-end and prints the expected error alongside the working case.

### Option B — step by step in `ysqlsh`

**Step 1.** Connect to any YB database:

```bash
/path/to/yugabyte/bin/ysqlsh -h 127.0.0.1 -p 5433 -U yugabyte -d yugabyte
```

**Step 2.** Create an `objects` table with a `cell_ids` array column and index it with `ybgin`:

```sql
DROP TABLE IF EXISTS objects;

CREATE TABLE objects (
  object_id int    PRIMARY KEY,
  cell_ids  int8[]
);

-- Three "objects" with overlapping S2-style cell coverings.
INSERT INTO objects VALUES
  (1, ARRAY[8520148959::int8, 8520148960]),
  (2, ARRAY[8520148960::int8, 8520148961]),
  (3, ARRAY[8520148961::int8, 8520148962]);

CREATE INDEX objects_cell_idx ON objects USING ybgin (cell_ids);
```

**Step 3. CASE 1 — Single-cell lookup (works).**

```sql
SELECT object_id FROM objects
 WHERE cell_ids @> ARRAY[8520148959::int8];
```

Expected: returns `object_id = 1`.

**Step 4. CASE 2 — Multi-cell OR via `&&` (CRASHES).**

```sql
SELECT object_id FROM objects
 WHERE cell_ids && ARRAY[8520148959::int8, 8520148960, 8520148961];
```

Expected:

```
ERROR:  unsupported ybgin index scan
DETAIL:  ybgin index method cannot use more than one required scan entry: got 3.
```

**Step 5. (Optional) verify the planner actually chose the `ybgin` index before it errored.**

```sql
EXPLAIN SELECT object_id FROM objects
 WHERE cell_ids && ARRAY[8520148959::int8, 8520148960, 8520148961];
```

Expected plan:

```
Index Scan using objects_cell_idx on objects
  Index Cond: (cell_ids && '{8520148959,8520148960,8520148961}'::bigint[])
```

So the planner did select the index — the crash happens inside the `ybgin` access method itself at execution time, not at planning time.

**Step 6. Clean up.**

```sql
DROP TABLE objects;
```

## Why `@>` is not the workaround

A natural follow-up: `@> ARRAY[100::int8, 200, 300]` also uses the `ybgin` index and does NOT crash. Can't we just use that for spatial queries?

No, because `@>` has the wrong semantic. Given a row with cells `[C1, C2, C3]` and a query with cells `[C4, C5, C6]`:

| Operator | Semantic | Spatial meaning |
|---|---|---|
| `row.cells @> query.cells` | Row contains **ALL** of the query's cells | Row must cover the **entire** query area — only rows whose geometry is bigger than the envelope can match. Points, short lines, and small polygons are always excluded. |
| `row.cells && query.cells` | Row **overlaps ANY** of the query's cells | What we actually want: any single cell in common means the shapes are spatially near each other. |

Using `@>` for spatial queries would miss 99% of correct answers, because a point (1 cell) can never "contain" a multi-cell query array.

You can simulate `&&` by running N separate single-key `@>` lookups and `UNION ALL`-ing the results, but that is structurally identical to what our B-tree mapping table already does — without gaining the Hilbert range-scan (`BETWEEN`) trick that lets us catch all descendants of a cell with a single scan. See the comparison table below.

## What the bug actually is

The `ybgin` access method explicitly rejects any scan where more than one "required scan entry" is needed.  The guard is in `yugabyte-db/src/postgres/src/backend/access/ybgin/ybginget.c:408-414`:

```c
/*
 * For now, only handle the case where there's one required scan entry
 */
if (key->nrequired != 1)
    ereport(ERROR,
            (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
             errmsg("unsupported ybgin index scan"),
             errdetail("ybgin index method cannot use"
                       " more than one required scan entry: got %d.",
                       key->nrequired)));
```

There is a sibling guard a few lines above (`so->nkeys != 1`) that rejects multi-column scans. Both are marked "For now" — i.e., deliberate not-yet-implemented guards, not incidental bugs.

### Operators that trigger the crash
| Operator | Query shape | Works on `ybgin`? |
|---|---|---|
| `cell_ids @> ARRAY[100]` | single cell | ✅ |
| `cell_ids @> ARRAY[100, 200]` | contains ALL (AND) | ✅ (but wrong semantics for spatial) |
| `cell_ids && ARRAY[100, 200, 300]` | overlaps ANY (OR) | ❌ |
| `data ?\| ARRAY['x','y','z']` | jsonb key exists ANY (OR) | ❌ |
| `v @@ to_tsquery('x \| y')` | tsquery OR | ❌ |
| `v @@ to_tsquery('x & y')` | tsquery AND over multiple keys | ❌ (separate branch) |
| **`s2_cell = ANY (ARRAY[…])`** | **spatial "any-of-N-cells"** | **❌** |

All of the ❌ rows hit the same `nrequired != 1` guard.

## Why this killed our first spatial extension

Our first prototype (`yb_geospatial2`) used the CockroachDB / Spanner-V3 "S2 + GIN" pattern: store a row's S2 covering cells as an `int8[]` column, and index with `USING ybgin`. The query time lookup was:

```sql
SELECT id FROM shapes
 WHERE s2_cells && ST_S2Covering(query_envelope);   -- multi-cell OR
```

That is **precisely the `&&` shape above with a large array**, and it hits the `nrequired != 1` guard on any non-trivial query. The extension "worked" for trivial 1-cell coverings and errored out for any realistic query.

### The workaround we built in `yb_geospatial_s2`

Instead of an inverted index we keep a normal range-sharded B-tree mapping table with primary key `(s2_cell ASC, id)`. We replace the multi-key OR with:
- one `BETWEEN range_min AND range_max` range scan per covering cell (descendants, via S2's Hilbert-curve property), and
- one `s2_cell = ANY (ancestors)` probe per cell (ancestors),
- combined with `UNION ALL` (not `OR`), because YB does not have a BitmapOr executor and `OR` degrades to a Seq Scan.

### Why the B-tree approach is actually better than a `@>` GIN workaround

| | `@>` GIN workaround (one-key-at-a-time) | Our B-tree mapping table |
|---|---|---|
| Works on YB | ✅ | ✅ |
| Hilbert range scans (`BETWEEN`) to catch all descendants in one scan | ❌ — GIN has no range semantics | ✅ — B-tree is range-sharded on `s2_cell` |
| Handles ancestors | Via parent expansion at write time (10–50× index bloat) | Via `= ANY(ancestors)` walked at query time |
| Index size | Large | Small (covering cells only) |

The B-tree `BETWEEN` trick is the real win. For a single query cell that has thousands of indexed descendants in the index, our approach catches them all in one range sweep, while GIN-with-`@>` would require either enumerating every descendant explicitly (impractical) or storing every ancestor at write time (heavy bloat).

## Official regression tests that document the failures

YB's own test suite already encodes these errors as expected behavior (grep for `"cannot use more than one required scan entry"`):

- `src/postgres/src/test/regress/expected/yb.orig.ybgin.out`
- `src/postgres/src/test/regress/expected/yb.orig.ybgin_misc.out`
- `src/postgres/src/test/regress/expected/yb.orig.ybgin_operators.out`
- `src/postgres/src/test/regress/expected/yb.orig.ybgin_pushdown.out`
- `src/postgres/src/test/regress/expected/yb.port.tsearch.out`
- `src/postgres/src/test/regress/expected/yb.port.jsonb.out`

These files are part of the YB repo's regression suite — meaning CI would fail if the error were different or absent. So the behavior is fully stable; it does not change version to version.

## What would "fix" this

Two pieces of work would unblock CockroachDB-style spatial GIN on YB:

1. **Lift the `nrequired != 1` guard in `ybginget.c`.** The standard PG GIN implementation handles multi-required-entry scans by walking each entry's posting list and merging them; `ybgin` would need the equivalent logic, distributed across DocDB tablets.
2. **Lift the `so->nkeys != 1` guard.** Same idea, different code path — this blocks combined conditions like `tags @@ 'a' AND tags @@ 'b'` at the multi-scan-key level.

Until both are done, GIN-based spatial indexing is not viable on YB, and the B-tree mapping-table pattern remains the right answer.

## If you want to see the sibling guard

The `so->nkeys != 1` guard is at `ybginget.c:383-391` (just above `nrequired`). You can trigger it by running a tsquery that forces multiple scan keys (see `yb.port.tsearch.out:362`).
