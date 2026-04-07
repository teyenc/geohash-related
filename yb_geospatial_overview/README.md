# yb_geospatial Extension — Technical Overview

> Source: `yugabyte-db/src/postgres/yb-extensions/yb_geospatial/yb_geospatial--1.0.sql`
>
> A pure SQL/PL-pgSQL PostGIS-compatible geospatial extension for YugabyteDB.
> Zero C extensions required. Inspired by geospatial_v05 (farrell0-yb).

---

## 1. Data Types

The extension defines three composite types. Because they are plain SQL composites (not C-backed opaque types), they work on every YB node without special binary deployment.

### 1.1 `geometry`

```sql
CREATE TYPE geometry AS (
   lon   double precision[],
   lat   double precision[]
);
```

Two parallel arrays store vertex coordinates. A **point** is a single-element array, a **linestring** is two elements, and a **polygon** is three or more. This representation avoids WKB parsing at query time and keeps coordinate access O(1) by index.

### 1.2 `geography`

```sql
CREATE TYPE geography AS (
   lon   double precision[],
   lat   double precision[]
);
```

Structurally identical to `geometry`. The type distinction tells functions to use spherical/ellipsoidal math (Haversine or Vincenty) and return results in **meters / square meters** rather than planar degree units. Implicit casts exist in both directions.

### 1.3 `box2d`

```sql
CREATE TYPE box2d AS (
   xmin double precision,
   ymin double precision,
   xmax double precision,
   ymax double precision
);
```

Bounding-box type used by GeoServer for `::box2d` casts and the `<->` distance operator on bounding boxes. Implicit casts from/to `geometry` are provided.

---

## 2. Schema and Indexing Strategy

The reference table shipped with the extension is `my_mapdata`. It stores POI records with both raw lat/lng text columns, a `geometry` column, and precomputed geohash columns at two precisions:

| Column | Purpose |
|---|---|
| `geo_hash10` | Full 10-character geohash of the point |
| `geo_hash8` | First 8 characters (coarser) |
| `geom` | `geometry` composite (the point itself) |

### Indexes

| Index | Key Expression | Use Case |
|---|---|---|
| `ix_my_mapdata2` | `(geo_hash10, md_name)` | Exact cell + name lookup |
| `ix_mapdata3` | `(LEFT(geo_hash10, 5), md_name)` | Large viewport / "speed = 80" driving |
| `ix_mapdata4` | `(LEFT(geo_hash10, 6), md_name)` | Medium viewport / walking |
| `ix_mapdata_geo_hash8` | `(geo_hash8)` | Small viewport / street-level |

The key insight: **geohash prefixes are the spatial index**. Instead of an R-tree (which is hard to distribute), we convert a 2D spatial query into a set of 1D string-prefix lookups that YB's LSM-based distributed storage handles natively.

---

## 3. What Gets Pushed Down to the Database Layer

Because every function is SQL or PL/pgSQL and marked `IMMUTABLE`, YugabyteDB can evaluate them on the TServer that owns the data tablet. Nothing needs to be shipped to a separate geometry engine.

### 3.1 Compute Pushdown

| Computation | Where it runs | Implementation |
|---|---|---|
| Haversine distance | TServer (PL/pgSQL) | `lm__haversine_distance` — great-circle on sphere R=6371 km |
| Vincenty distance | TServer (PL/pgSQL) | `lm__vincenty_distance` — WGS-84 ellipsoid, sub-mm accuracy |
| Point-in-polygon | TServer (PL/pgSQL) | `point_in_polygon` — ray-casting algorithm |
| Polygon area | TServer (PL/pgSQL) | Shoelace formula (geometry) / L'Huilier spherical excess (geography) |
| Segment intersection | TServer (PL/pgSQL) | Orientation + cross-product in `lm__segments_cross` |
| Convex hull | TServer (PL/pgSQL) | Graham scan in `ST_ConvexHull` |
| Douglas-Peucker simplify | TServer (PL/pgSQL) | Stack-based iterative in `ST_Simplify` |
| WKB / EWKB / TWKB encoding | TServer (PL/pgSQL) | Byte-level construction for GeoServer transport |

### 3.2 Index Pushdown (Geohash → Distributed Index)

A spatial bounding-box query is translated into a set of geohash prefix matches:

```
GeoServer viewport (bbox)
        │
        ▼
geohash_cells_for_bbox(lon_min, lat_min, lon_max, lat_max)
        │
        ▼
Set of geohash strings at precision 5 / 6 / 8
        │
        ▼
WHERE LEFT(geo_hash10, N) IN ('9x0qs', '9x0qt', ...)
        │
        ▼
YB distributed index scan (ix_mapdata3 / ix_mapdata4 / ix_mapdata_geo_hash8)
```

This is the core trick: **a 2D spatial filter becomes a 1D prefix-IN filter** that YB can push down to individual tablets via range scans on the LSM index. No distributed R-tree needed.

### 3.3 What Does NOT Get Pushed Down

- **Polygon clipping** (`ST_Intersection`, `ST_Difference`) — these are evaluated after rows are fetched and are O(n*m) in vertex count. They are used for rendering, not filtering.
- **Random point generation** (`ST_GeneratePoints`) — marked `VOLATILE`, so it cannot be pushed into index scans.

---

## 4. Zoom In / Zoom Out Strategy

The extension implements a multi-level strategy so that wide (zoomed out) viewports stay fast while narrow (zoomed in) viewports stay precise.

### 4.1 Adaptive Geohash Precision

`geohash_cells_for_bbox` (the auto-precision overload) measures the viewport span in miles and selects the coarsest geohash precision that still covers it efficiently:

| Viewport Span | Geohash Precision | Cell Size (~miles) | Index Used |
|---|---|---|---|
| > 20 miles | 5 | ~2.4 mi | `ix_mapdata3` |
| 1–20 miles | 6 | ~0.6 mi | `ix_mapdata4` |
| < 1 mile | 8 | ~0.019 mi | `ix_mapdata_geo_hash8` |

When the user zooms **out**, fewer, larger cells cover the viewport — the IN-list stays small. When the user zooms **in**, the cells get smaller and more precise — fetching only the points actually on screen.

### 4.2 Geometry Simplification (Rendering Optimization)

GeoServer requests simplified geometries at low zoom. The extension provides two algorithms:

| Function | Algorithm | Best For |
|---|---|---|
| `ST_Simplify(geom, tolerance)` | Douglas-Peucker | Lines and polygon outlines |
| `ST_Simplify_vw(geom, area_threshold)` | Visvalingam-Whyatt | Area-preserving simplification |
| `ST_SimplifyPreserveTopology(geom, tolerance)` | Delegates to Douglas-Peucker | GeoServer calls this name |

At zoom level 5 (continental), a polygon might go from 200 vertices to 12. At zoom level 15 (street), all vertices are kept.

### 4.3 Payload Compression (TWKB)

`ST_AsTWKB(geom, precision)` encodes geometries into Tiny Well-Known Binary:

- Coordinates are multiplied by 10^precision, rounded to integers, then **delta-compressed** (each coordinate stored as difference from previous).
- Deltas are **zigzag-encoded** and written as **varints** (protobuf-style).
- At zoom level 5, `precision=2` might be enough (1/100 degree ≈ 1 km) — coordinates collapse to 1-2 bytes each.
- At zoom level 15, `precision=6` keeps sub-meter accuracy.

This dramatically reduces the bytes-on-wire between YugabyteDB and GeoServer.

### 4.4 Bounding Box Pre-filter (`&&` Operator)

Before expensive intersection or containment tests, the `&&` operator performs an O(n) bounding-box overlap check:

```sql
WHERE geom && ST_MakeEnvelope(lon_min, lat_min, lon_max, lat_max)
```

This cheaply rejects any geometry whose bbox does not overlap the viewport, avoiding the costlier `ST_Intersects` or `point_in_polygon` computation.

---

## 5. Common Query Patterns

### 5.1 Viewport Query (What GeoServer Sends)

Fetch all points visible in the current map viewport:

```sql
SELECT md_pk, md_name, ST_AsTWKB(geom, 6) AS geom_twkb
FROM my_mapdata
WHERE LEFT(geo_hash10, 6) IN (
    SELECT geohash_cells_for_bbox(-112.0, 40.5, -111.9, 40.6)
)
AND geom && ST_MakeEnvelope(-112.0, 40.5, -111.9, 40.6);
```

**Flow**: geohash IN-list narrows to relevant tablets → `&&` bbox rejects false positives → `ST_AsTWKB` compresses output.

### 5.2 Radius / Proximity Search

Find all POIs within 5 miles of a given location:

```sql
SELECT md_pk, md_name,
       ST_DistanceSphere(geom, ST_MakePoint(-111.97, 40.52)) AS dist_m
FROM my_mapdata
WHERE LEFT(geo_hash10, 5) IN (
    SELECT unnest(string_to_array(
        geohash_in_list_within_miles(
            geohash_encode(40.52, -111.97, 10), 5
        ), ','
    ))
)
AND ST_DWithin(
    geom::geography,
    ST_MakePoint_Geog(-111.97, 40.52),
    5 * 1609.34  -- 5 miles in meters
)
ORDER BY dist_m;
```

**Flow**: `geohash_in_list_within_miles` generates a grid of geohash-5 cells covering the 5-mile radius → index scan → `ST_DWithin` (Haversine) does precise circle filter.

### 5.3 Polygon Coverage

Find all precision-8 geohash cells entirely inside a polygon defined by geohash vertices:

```sql
SELECT * FROM geohash8_fully_within_polygon(
    ARRAY['9x0qs0fd', '9x0qs0ff', '9x0qs0fu', '9x0qs0fs']
);
```

Uses `point_in_polygon` on all four corners of each candidate cell. Useful for geofencing or regional analytics.

### 5.4 GeoServer Layer Discovery

GeoServer probes these on connection startup:

```sql
SELECT PostGIS_Lib_Version();               -- Returns '2.1.8'
SELECT * FROM geometry_columns;             -- Returns (public, my_mapdata, geom, 2, 4326, POINT)
SELECT * FROM geography_columns;            -- Returns empty (no geography columns in tables)
SELECT srid, srtext FROM spatial_ref_sys;   -- Returns EPSG:4326
SELECT ST_EstimatedExtent('public', 'my_mapdata', 'geom');  -- Falls back to ST_Extent (full scan, cached)
```

These compatibility shims make GeoServer believe it is talking to PostGIS 2.1.

---

## 6. Function Catalog (by Category)

### Constructors

| Function | Returns | Description |
|---|---|---|
| `ST_MakePoint(lon, lat)` | `geometry` | Single point |
| `ST_MakePoint(lon, lat, z)` | `geometry` | 3D point (Z discarded) |
| `ST_MakePolygon(lon[], lat[])` | `geometry` | Polygon from vertex arrays |
| `ST_MakeEnvelope(xmin, ymin, xmax, ymax [, srid])` | `geometry` | Rectangle (SW→SE→NE→NW) |
| `ST_MakeLine(a, b)` | `geometry` | LineString from two points |
| `ST_GeomFromText(wkt [, srid])` | `geometry` | Parse WKT (POINT, LINESTRING, POLYGON) |
| `ST_GeomFromGeoJSON(json)` | `geometry` | Parse GeoJSON |
| `ST_GeomFromWKB(wkb [, srid])` | `geometry` | Decode WKB bytes |

### Accessors

| Function | Returns | Description |
|---|---|---|
| `ST_X(geom)` | `double precision` | Longitude of point |
| `ST_Y(geom)` | `double precision` | Latitude of point |
| `ST_NPoints(geom)` | `integer` | Vertex count |
| `ST_XMin/XMax/YMin/YMax(geom)` | `double precision` | Bounding box edges |
| `GeometryType(geom)` | `text` | 'POINT', 'LINESTRING', 'POLYGON' |
| `ST_StartPoint / ST_EndPoint / ST_PointN` | `geometry` | Vertex extraction |

### Spatial Relationships

| Function | Returns | Description |
|---|---|---|
| `ST_Intersects(a, b)` | `boolean` | Any shared area/edge/point |
| `ST_Contains(a, b)` | `boolean` | B entirely inside A (with interior point) |
| `ST_Within(a, b)` | `boolean` | A entirely inside B (= `ST_Contains(b, a)`) |
| `ST_DWithin(a, b, dist)` | `boolean` | Planar distance ≤ threshold |
| `ST_Touches(a, b)` | `boolean` | Boundaries touch, interiors don't |
| `ST_Crosses(a, b)` | `boolean` | Partial interior intersection (line/polygon) |
| `ST_Overlaps(a, b)` | `boolean` | Same dimension, shared but not contained |
| `ST_Equals(a, b)` | `boolean` | Topological equality |
| `ST_Disjoint(a, b)` | `boolean` | No intersection at all |

### Measurements

| Function | Returns | Description |
|---|---|---|
| `ST_Distance(geom, geom)` | `double precision` | Minimum planar distance (degrees) |
| `ST_Distance(geog, geog)` | `double precision` | Haversine distance (meters) |
| `ST_Distance(geog, geog, true)` | `double precision` | Vincenty distance (meters, sub-mm) |
| `ST_DistanceSphere(geom, geom)` | `double precision` | Great-circle distance (meters) |
| `ST_DistanceSpheroid(geom, geom)` | `double precision` | Vincenty (meters) |
| `ST_Area(geom)` | `double precision` | Shoelace formula (sq degrees) |
| `ST_Area(geog)` | `double precision` | Spherical excess (sq meters) |
| `ST_Length(geom)` | `double precision` | Planar segment sum |
| `ST_Perimeter(geom)` | `double precision` | Closed ring perimeter |
| `ST_Azimuth(a, b)` | `double precision` | Bearing in radians from north |

### Geohash Functions

| Function | Returns | Description |
|---|---|---|
| `geohash_encode(lat, lon, prec)` | `text` | Lat/lon → geohash string |
| `geohash_decode_bbox(hash)` | `TABLE` | Geohash → bounding box |
| `geohash_cell_center(hash)` | `TABLE` | Geohash → center point |
| `geohash_adjacent(hash, dir)` | `text` | Neighbor cell in n/s/e/w |
| `geohash_neighbors(hash)` | `jsonb` | All 8 surrounding cells |
| `geohash_move(hash, dir, steps)` | `text` | Walk N steps in a direction |
| `geohash_in_list_within_miles(hash, miles)` | `text` | IN-clause covering a radius |
| `geohash_cells_for_bbox(...)` | `SETOF text` | All cells covering a bbox |
| `geohash8_fully_within_polygon(hashes[])` | `SETOF text` | Precision-8 cells inside a polygon |

### Output / Encoding

| Function | Returns | Description |
|---|---|---|
| `ST_AsText(geom)` | `text` | WKT output |
| `ST_AsGeoJSON(geom)` | `text` | GeoJSON output |
| `ST_AsBinary(geom)` | `bytea` | OGC WKB (little-endian) |
| `ST_AsEWKB(geom)` | `bytea` | Extended WKB with SRID 4326 |
| `ST_AsTWKB(geom, prec)` | `bytea` | Tiny WKB (delta + varint compressed) |

### Geometry Processing

| Function | Returns | Description |
|---|---|---|
| `ST_Centroid(geom)` | `geometry` | Center of mass (shoelace-weighted) |
| `ST_Envelope(geom)` | `geometry` | Bounding box as polygon |
| `ST_ConvexHull(geom)` | `geometry` | Convex hull (Graham scan) |
| `ST_Intersection(a, b)` | `geometry` | Polygon intersection (Sutherland-Hodgman) |
| `ST_Union(a, b)` | `geometry` | Convex hull of combined vertices |
| `ST_Difference(a, b)` | `geometry` | A minus B |
| `ST_Buffer(geom, dist [, segs])` | `geometry` | Approximate buffer polygon |
| `ST_Simplify(geom, tol)` | `geometry` | Douglas-Peucker simplification |
| `ST_Simplify_vw(geom, area)` | `geometry` | Visvalingam-Whyatt simplification |
| `ST_ClipByBox2D(geom, box)` | `geometry` | Sutherland-Hodgman bbox clip |
| `ST_Translate / ST_Rotate / ST_Scale / ST_Affine` | `geometry` | Affine transforms |
| `ST_Project(geom, dist_m, azimuth)` | `geometry` | Forward geodesic projection |

### Operators

| Operator | Operands | Description |
|---|---|---|
| `&&` | `geometry, geometry` | Bounding-box overlap |
| `&&` | `geography, geography` | Bounding-box overlap (delegates to geometry) |
| `<->` | `geometry, geometry` | Centroid-to-centroid planar distance (KNN sorting) |
| `<->` | `geography, geography` | Great-circle distance (KNN sorting) |
| `<->` | `box2d, box2d` | Bounding-box gap distance |

---

## 7. Architecture Diagram

```
┌────────────────────────────────────────────────────────────┐
│                    GeoServer / App Layer                    │
│                                                            │
│  GetMap(bbox) ──► geohash_cells_for_bbox(bbox)             │
│                   picks precision 5/6/8 based on zoom      │
│                                                            │
│  SELECT ... WHERE LEFT(geo_hash10, N) IN (cells)           │
│               AND geom && ST_MakeEnvelope(bbox)            │
│                                                            │
│  Output: ST_AsTWKB(geom, prec)  or  ST_AsEWKB(geom)       │
├────────────────────────────────────────────────────────────┤
│                   YugabyteDB YSQL Layer                    │
│                                                            │
│  SQL / PL-pgSQL functions:                                 │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ geohash_encode/decode   ST_Intersects  ST_Contains   │  │
│  │ point_in_polygon        ST_Distance    ST_Simplify   │  │
│  │ Haversine / Vincenty    Shoelace area  Graham scan   │  │
│  │ WKB/EWKB/TWKB encode   ray-casting    Douglas-Peucker│ │
│  └──────────────────────────────────────────────────────┘  │
│                                                            │
│  All IMMUTABLE → evaluated on data-owning TServer          │
├────────────────────────────────────────────────────────────┤
│                YugabyteDB DocDB (Storage)                   │
│                                                            │
│  Tablets hold my_mapdata rows, sharded by md_pk HASH       │
│                                                            │
│  Secondary indexes (LSM-based, distributed):               │
│    ix_mapdata3      → LEFT(geo_hash10, 5) range scan       │
│    ix_mapdata4      → LEFT(geo_hash10, 6) range scan       │
│    ix_mapdata_geo_hash8 → geo_hash8 equality lookup        │
│                                                            │
│  Geohash prefix = 1D key → native distributed range scan   │
│  No R-tree needed                                          │
└────────────────────────────────────────────────────────────┘
```

---

## 8. Design Trade-offs

| Decision | Benefit | Cost |
|---|---|---|
| Pure PL/pgSQL, no C | Deploys on any YB cluster without binary compat issues | Slower than C-based PostGIS for heavy polygon operations |
| Geohash prefix as spatial index | Works with YB's distributed LSM indexes; no R-tree | Slight over-fetch at cell boundaries; cells are rectangles not circles |
| Composite type for geometry | Transparent to SQL; no custom I/O functions needed | No binary compression in storage; larger on-disk than PostGIS bytea |
| SRID always 4326 | Simplifies everything; no projection math needed | Cannot natively handle non-WGS84 coordinate systems |
| Vincenty for geography distance | Sub-millimeter accuracy on WGS-84 ellipsoid | Iterative algorithm; slower than Haversine for large batches |
| Convex-only polygon ops | Sutherland-Hodgman is fast and simple | `ST_Intersection` / `ST_Difference` are approximate for concave polygons |
