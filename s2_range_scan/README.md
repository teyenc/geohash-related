# S2 Range-Scan Trick — Interactive Explainer

Explains why Google Spanner's S2 spatial architecture (and our `yb_geospatial_s2`
implementation) can skip parent expansion entirely and still answer
"any-ancestor-any-descendant" spatial queries with a single B-tree range scan.

## What to look at

Open `s2_range_scan.html` in a browser (or Cursor canvas / any static server).

Sections:

1. **Anatomy** — the 64-bit S2 cell ID laid out bit-by-bit (face · path ·
   sentinel · padding). Each bit is color-coded; hover highlights.
2. **Interactive** — drag the level slider (0 = whole cube face, 30 = leaf).
   The widget computes `id`, `lsb`, `range_min`, `range_max` in the browser
   using exactly the same formula as `s2_cell_range_min/max` in our SQL.
3. **Before / after** — side-by-side comparison of traditional parent
   expansion (Elasticsearch / Lucene / older GIN) vs the S2 range-scan write
   path.
4. **Worked example** — real S2 cell IDs produced by `yb_geospatial_s2`'s
   trigger on a 7-POI live YugabyteDB cluster, grouped by S2 face. You can see
   the Bay Area POIs share a common high-order prefix (so one range catches
   all of them), while NYC / London / Tokyo each land on different faces.

## The formula

```sql
-- Same two lines as S2CellId::range_min / range_max in C++.
range_min(cell) = cell - ((cell & -cell) - 1)
range_max(cell) = cell + ((cell & -cell) - 1)
```

Live ports in the extension SQL: `yb_geospatial_s2--1.0.sql`, around line 283.
Upstream C++ reference: `deps/s2geometry/src/s2/s2cell_id.h`, lines 497
(`lsb()`) and 640–646 (`range_min()`, `range_max()`).

## Reproduce

```bash
# From code/ root:
cd yugabyte-db/src/postgres/yb-extensions/yb_geospatial_s2
# (rebuild + install, then):
ysqlsh -h 127.0.0.1 -p 5433 -U yugabyte <<SQL
CREATE EXTENSION IF NOT EXISTS yb_geospatial_s2;
CREATE TABLE pois (id serial PRIMARY KEY, name text, geom geometry);
SELECT create_spatial_index('pois', 'geom', 'id');
INSERT INTO pois(name, geom) VALUES
  ('SF',     ST_GeomFromText('POINT(-122.4 37.7)', 4326)),
  ('NYC',    ST_GeomFromText('POINT(-73.9 40.7)',  4326)),
  ('London', ST_GeomFromText('POINT(-0.1 51.5)',   4326));
SELECT name, s2_cell::bit(64) FROM pois JOIN pois_s2_index USING(id);
SQL
```

The second column is the same set of bit strings shown in the HTML's "Worked
example" section.
