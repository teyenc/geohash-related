# PostGIS / spatial-extension demo queries

A clipboard-friendly cheat sheet of the queries you ran in `bench_postgis`.
The same SQL works against the YB extensions (`bench_s2` / `bench_cgeo`) too —
both have utility-hook + planner-hook plumbing that translates these
PostGIS-flavored statements into their own index + lookup primitives.

How to open each engine:
```bash
/tmp/bench-open postgis    # vanilla PostgreSQL 15 + PostGIS 3.5 on :54321
/tmp/bench-open s2         # YB + yb_geospatial_s2 on :5433/bench_s2
/tmp/bench-open cgeo       # YB + c_geohash         on :5433/bench_cgeo
/tmp/bench-open geohash    # YB + Dan's pure-SQL    on :5433/bench_geohash
```

---

## 1. Build a tiny indexed point table

```sql
CREATE TABLE IF NOT EXISTS my_pts (
    id    bigserial PRIMARY KEY,
    name  text,
    lat   double precision,
    lon   double precision,
    geom  geometry
);

CREATE INDEX IF NOT EXISTS my_pts_gix ON my_pts USING gist (geom);
```

`USING gist (geom)` is real PostGIS on `bench_postgis`. On `bench_s2` and
`bench_cgeo`, the utility hook intercepts this exact statement and rewrites
it to `create_spatial_index(...)` / `create_cgeo_text_spatial_index(...)`
respectively — same syntax, different storage shape underneath.

## 2. Insert four cities

```sql
INSERT INTO my_pts (name, lat, lon, geom) VALUES
  ('NYC',     40.7128,  -74.0060, ST_GeomFromText('POINT(-74.0060 40.7128)',  4326)),
  ('London',  51.5074,   -0.1278, ST_GeomFromText('POINT(-0.1278  51.5074)',  4326)),
  ('Tokyo',   35.6762,  139.6503, ST_GeomFromText('POINT(139.6503 35.6762)',  4326)),
  ('Sydney', -33.8688,  151.2093, ST_GeomFromText('POINT(151.2093 -33.8688)', 4326));
```

`ST_GeomFromText('POINT(lon lat)', 4326)` is the one-call form that builds a
geometry AND stamps it with SRID 4326 (WGS84). An equivalent shorter form
is the implicit text cast `'SRID=4326;POINT(lon lat)'::geometry`.

## 3. Range query — find points in a 30 km × 30 km box around NYC

```sql
SELECT id, name FROM my_pts
 WHERE ST_Intersects(geom,
                     ST_MakeEnvelope(-74.20, 40.55, -73.80, 40.95, 4326));
-- expected: only NYC
```

PostGIS picks the GiST index for `ST_Intersects`. On the YB extensions the
planner hook rewrites this into
`id = ANY (SELECT spatial_candidates('my_pts', envelope))` (or the
c_geohash equivalent) so the index actually gets used.

## 4. Quick predicate sanity checks (no table needed)

### Two crossing diagonals

```sql
SELECT ST_Intersects(
  ST_GeomFromText('LINESTRING(0 0, 10 10)'),
  ST_GeomFromText('LINESTRING(0 10, 10 0)')
) AS intersects;
-- t   (the diagonals cross at (5,5))
```

### Open square boundary vs inner polygon — disjoint

```sql
SELECT ST_Intersects(
  ST_GeomFromText('LINESTRING(0 0, 10 0, 10 10, 0 10)'),
  ST_GeomFromText('POLYGON((2 2, 8 2, 8 8, 2 8, 2 2))')
) AS intersects;
-- f   (the unclosed line traces the OUTER border at x=0..10 / y=0..10;
--      the polygon sits entirely between x=2..8 / y=2..8 — they never touch)
```

### Polygon-with-hole — point in the hole is NOT contained

```sql
SELECT ST_Contains(
  ST_GeomFromText(
    'POLYGON((0 0, 10 0, 10 10, 0 10, 0 0),
             (3 3, 7 3, 7 7, 3 7, 3 3))'
  ),
  ST_GeomFromText('POINT(5 5)')
) AS contains;
-- f   (5,5 sits in the inner ring = the hole = not in the polygon)
```

The first ring `(0 0 … 10 10 … 0 0)` is the exterior; subsequent rings are
holes. `ST_Contains(poly, pt)` correctly returns false because (5,5) is
inside the hole, not the polygon's filled area.

---

## 5. POI dataset queries (already loaded in bench_postgis / bench_s2 /
##    bench_cgeo / bench_dans / bench_geohash)

### Q2 — POIs within 50 km of Fort Collins, CO
```sql
SELECT count(*) FROM my_mapdata
 WHERE ST_DWithin(geom::geography,
                  ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)::geography,
                  50000, true);
-- expected: 25 337
```

### Q3 — POIs in the ~200 km Colorado Front Range box
```sql
SELECT count(*) FROM my_mapdata
 WHERE ST_Intersects(geom,
                     ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326));
-- expected: 190 060
```

### Q4 — rivers intersecting the western-US envelope
```sql
SELECT count(*) FROM rivers
 WHERE ST_Intersects(geom,
                     ST_MakeEnvelope(-125.0, 30.0, -100.0, 50.0, 4326));
-- expected: 32 489 (PostGIS / S2 / Dan's all agree within 1-616 rows;
--                   see results/benchmark_3way.md for the full table)
```

### Q6 — 10 nearest POIs to Fort Collins (KNN, only on PostGIS / Dan's)
```sql
SELECT md_pk, md_name, md_city
  FROM my_mapdata
 ORDER BY geom <-> ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326)
 LIMIT 10;
-- (PostGIS uses the GiST index for KNN automatically; Dan's seq-scans;
--  S2 has its own helper: SELECT * FROM spatial_knn('my_mapdata',
--      ST_SetSRID(ST_MakePoint(-105.0775, 40.5853), 4326), 10, 'md_pk');)
```

---

## 6. EXPLAIN to see which engine you're hitting

```sql
EXPLAIN (ANALYZE, BUFFERS)            -- on bench_postgis
SELECT count(*) FROM my_mapdata
 WHERE ST_Intersects(geom,
                     ST_MakeEnvelope(-106.20, 38.80, -103.70, 40.80, 4326));
-- look for: "Bitmap Index Scan on my_mapdata_gix"

EXPLAIN (ANALYZE, DIST)               -- on bench_s2
-- ... same query ...
-- look for: "id = ANY (SELECT spatial_candidates('my_mapdata', ...))"
--            and "Index Scan using my_mapdata_s2_index_pkey"

EXPLAIN (ANALYZE, DIST)               -- on bench_cgeo
-- ... same query ...
-- look for: "md_pk IN (SELECT cgeo_text_spatial_candidates(...))"
--            and "Index Scan using my_mapdata_cgeo_index_pkey"

-- (Dan's bench_geohash will Seq-Scan rivers/my_mapdata for everything
--  that doesn't match its hand-written LEFT(geo_hash10, k) = ANY(...) idiom.)
```
