# The `ybgin` multi-key OR scan limitation

This folder documents a limitation in YugabyteDB's `ybgin` index that directly shaped the architecture of our `yb_geospatial_s2` extension. A spatial query's natural shape — "find rows matching ANY of these N cells" — is exactly the shape that `ybgin` rejects today. This doc shows the bug, gives you a 10-second reproducer, cites the source, and explains the consequence for spatial indexing.

## TL;DR

```sql
CREATE TABLE demo (id int PRIMARY KEY, tags text[]);
CREATE INDEX ON demo USING ybgin (tags);

SELECT id FROM demo WHERE tags @> ARRAY['a'];               -- ✅ works (single-key)
SELECT id FROM demo WHERE tags && ARRAY['a','b','c'];       -- ❌ ERROR (multi-key OR)
--     ERROR:  unsupported ybgin index scan
--     DETAIL:  ybgin index method cannot use more than one required
--              scan entry: got 3.
```

The `&&` operator is "overlaps ANY of these keys" — the exact semantics a spatial index needs. That OR semantic is what triggers the crash. (Note: `@>` with multiple elements also uses the index without crashing, but `@>` means "contains ALL" — wrong semantics for spatial queries. See "Why `@>` is not the workaround" below.)

## Contents of this folder

| File | What it is |
|---|---|
| `README.md` | This document |
| `ybgin_bug_repro.sql` | Minimal `text[]` reproducer (works / crashes) |
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

1. Connect to any YB database:
   ```bash
   /path/to/yugabyte/bin/ysqlsh -h 127.0.0.1 -p 5433 -U yugabyte -d yugabyte
   ```

2. Create a table with an array column and a `ybgin` index on it:
   ```sql
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
   ```

3. Run the two test cases:

   **CASE 1 — Single-key lookup (works):**
   ```sql
   SELECT id FROM ybgin_bug_demo WHERE tags @> ARRAY['alpha'];
   ```
   Expected: returns `id = 1`.

   **CASE 2 — OR over multiple keys via `&&` (CRASHES):**
   ```sql
   SELECT id FROM ybgin_bug_demo WHERE tags && ARRAY['alpha', 'bravo', 'charlie'];
   ```
   Expected:
   ```
   ERROR:  unsupported ybgin index scan
   DETAIL:  ybgin index method cannot use more than one required scan entry: got 3.
   ```

4. (Optional) verify the planner actually chose the `ybgin` index before it errored:
   ```sql
   EXPLAIN SELECT id FROM ybgin_bug_demo WHERE tags && ARRAY['alpha','bravo','charlie'];
   --  Index Scan using ybgin_bug_idx on ybgin_bug_demo
   --    Index Cond: (tags && '{alpha,bravo,charlie}'::text[])
   ```
   So the planner did select the index — the crash happens inside the `ybgin` access method itself at execution time, not at planning time.

5. Clean up:
   ```sql
   DROP TABLE ybgin_bug_demo;
   ```

## Why `@>` is not the workaround

A natural follow-up: `@> ARRAY['a','b','c']` also uses the `ybgin` index and does NOT crash. Can't we just use that for spatial queries?

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
| `tags @> ARRAY['x']` | single key | ✅ |
| `tags @> ARRAY['x','y']` | contains ALL (AND) | ✅ (but wrong semantics for spatial) |
| `tags && ARRAY['x','y','z']` | overlaps ANY (OR) | ❌ |
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
