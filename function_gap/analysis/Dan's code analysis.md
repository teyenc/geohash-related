# Summary

* Section 1: type, overlap, and some encoding decoding stuffs  
* Section 2: index / schema  
* Section 3: curved logic on the earth surface  
* Section 4:   
  * Get the middle point in a hash  
  * Turn a string into visual box etc  
  * Shift the shape  
  * Etc  
* Section 5:  
  * Check if there’s intersection between 2 shapes  
  * Point in shape  
  * etc   
* Section 6:  
  * Tier 1 functions \- API interface  
* Section 7:  
  * Tier 2 functions  
* Section 8:  
  * Tier 3 functions

#### Something regarding format …..

```
The number -111.97 (for human) is stored as these 8 bytes:

Little-endian (WKB, Geoserevr):     ae  47  e1  7a  fc  f8  5b  c0
                          ←── least significant first

Big-endian (PostgreSQL / YB):  c0  5b  f8  fc  7a  e1  47  ae
                          ←── most significant first

```

```
WKT: POINT(x y), LINESTRING(x1 y1, x2 y2), or POLYGON((x1 y1, ..., x1 y1)).
GeoJSON: {"type":"Point","coordinates":[x,y]}.
```

ST\_ means spatial type

# yb\_geospatial Function Reference

Plain-English explanations for all functions in `yb_geospatial--1.0.sql`, in the exact order they appear in the file.

Source: [geospatial\_v05](https://github.com/farrell0-yb/geospatial_v05) by farrell0-yb.

---

## Section 1: Geometry Type, Constructors, WKB/EWKB/TWKB, Operators

### `geometry` (TYPE)

Composite type `(lon double precision[], lat double precision[])`. A point is a single-element array. A polygon is 3+ vertices. No explicit closing required.

### `ST_MakePoint(lon, lat)`

Creates a single-point geometry.

### `ST_MakePolygon(lon[], lat[])`

Creates a polygon from parallel vertex arrays.

### `ST_MakeEnvelope(xmin, ymin, xmax, ymax)`

Creates a rectangle geometry from bounding box corners.

### `ST_MakeEnvelope(xmin, ymin, xmax, ymax, srid)`

5-arg overload. SRID accepted but ignored. Delegates to 4-arg version.

### `PostGIS_Version()`

Returns `'2.1 USE_GEOS=0'`. GeoServer version detection stub.

### `PostGIS_Lib_Version()`

Returns `'2.1.8'`. GeoServer version detection stub.

### `PostGIS_Full_Version()`

Returns a full version string noting YugabyteDB PL/pgSQL shim.

### `PostGIS_GEOS_Version()`

Returns NULL. GEOS is not available.

### `ST_SRID(geometry)`

Always returns 4326\.

### `ST_SetSRID(geometry, srid)`

Returns the geometry unchanged.

### `ST_Transform(geometry, srid)`

Returns the geometry unchanged. In real PostGIS this reprojects coordinates.

### `ST_AsBinary(geometry)`

Encodes geometry to OGC Well-Known Binary (little-endian). Handles POINT, LINESTRING, POLYGON, and empty geometries.  
So basically transfer YB language to Geoserver language

### `lm__float8_to_le_bytea(val)` (internal)

Converts a 64-bit float to 8 little-endian bytes. Uses `float8send()` then reverses byte order.

```
C0 5B F8 FC 7A E1 47 AE -> AE 47 E1 7A FC F8 5B C0
```

### `lm__int32_to_le_bytea(val)` (internal)

Converts a 32-bit integer to 4 little-endian bytes via bit shifting.

### `geometry_overlaps_bbox(a, b)` (internal)

Backing function for the `&&` operator. Tests AABB (Axis-Aligned Bounding Box) overlap.

### `&&` (OPERATOR: geometry, geometry)

Bounding-box overlap. Returns true if AABBs intersect.

### `lm__st_extent_transfn(state, val)` (internal)

Transition function for `ST_Extent` aggregate. Expands bounding box.   
Input a box and a dot, return a same or bigger box (this is just growing a box)

### `ST_Extent(geometry)` (AGGREGATE)

Computes a single bounding box that encloses all input geometries. (uses the lm\_\_st\_extent\_transfn above)

### `ST_AsEWKB(geometry)`

Extended WKB. Same as `ST_AsBinary` but embeds SRID 4326 into the byte header.  
TBD

### `ST_Force2D(geometry)` / `ST_Force_2D(geometry)`

Identity. Always 2D. (stub)

### `ST_NDims(geometry)`

Always returns 2\. (stub)

### `ST_GeomFromText(wkt, srid)`

(stub)  
2-arg version. SRID accepted but ignored. Delegates to 1-arg version (defined later in Tier 2).

### `ST_GeomFromWKB(bytea, srid)` / `ST_GeomFromWKB(bytea)`

Decodes OGC WKB binary back to geometry. Handles POINT, LINESTRING, POLYGON. Skips SRID bytes if present.

### `lm__le_bytea_to_float8(bytea, offset)` (internal)

Reads 8 little-endian bytes from a bytea at the given offset and returns a float8. Reverses bytes then calls `float8recv()`.  
reverse a WKB and make it float 

```
WKB bytes at offset (little-endian):  ae 47 e1 7a fc f8 5b c0
                                      ↓  reverse  ↓
Big-endian for float8recv:            c0 5b f8 fc 7a e1 47 ae
                                      ↓  float8recv  ↓
Result:                               -111.97
```

### `lm__le_bytea_to_int32(bytea, offset)` (internal)

Reads 4 little-endian bytes and returns an integer. So basically covert geoserver format to human readable

### `ST_MakePoint(lon, lat, z)`

3-arg version. Z is discarded (always 2D). (stub)

### `ST_EstimatedExtent(schema, table, column)`

\-\> Computes a single bounding box that encloses all input geometries.

GeoServer calls this for fast bbox estimation. Falls back to `ST_Extent` (full table scan). Slow but correct. GeoServer caches the result.

In PostGIS there’s `ST_EstimatedExtent` and `ST_Extent`, they are different in PostGIS, in our extension they are the same (so far)

### `ST_Estimated_Extent(...)`

Computes a single bounding box that encloses all input geometries. (same thing)  
Legacy alias (extra underscore) for PostGIS \< 2.1 clients.

### `ST_SimplifyPreserveTopology(geometry, tolerance)`

Shim. Delegates to `ST_Simplify` (true topology preservation requires GEOS).

makes a smooth, detailed shape look rougher to save bandwidth and rendering time when you're too far away to notice the difference.

### `geometry_distance(a, b)` (internal)

Given two geometries, it returns one number. Backing function for `<->`.

### `<->` (OPERATOR: geometry, geometry)

Given two geometries, it returns one number. the distance between their centroids. Used by GeoServer for `ORDER BY geom <-> point` KNN sorting.

### `box2d` (TYPE)

Bounding box type `(xmin, ymin, xmax, ymax)`.

### `lm__geometry_to_box2d(geometry)` 

Takes geometry and make it bounding box

### `lm__box2d_to_geometry(box2d)` (internal)

Takes bounding box make it geometry

### CAST geometry \<-\> box2d

Implicit casts in both directions.

### `box2d_distance(a, b)` (internal)

Minimum distance between two bounding boxes. Zero if they overlap.

### `<->` (OPERATOR: box2d, box2d)

Minimum bbox distance. Uses box2d\_distance. 

### `lm__twkb_uvarint(val)` (internal)

Encodes an unsigned integer as a protobuf-style variable-length integer.  
TBD

### `lm__twkb_svarint(val)` (internal)

Zigzag-encodes a signed integer, then varint-encodes it.  
TBD

### `ST_AsTWKB(geometry, precision)`

Tiny WKB. Delta-compressed coordinates with protobuf-style varint encoding. Much smaller than WKB.  
TBD

---

## Section 2: GeoServer Metadata

### `spatial_ref_sys` (TABLE)

Contains one row: EPSG:4326 (WGS 84). GeoServer queries this to validate SRIDs.

### `geometry_columns` (VIEW)

Reports `my_mapdata.geom`, SRID 4326, type POINT. GeoServer reads this for layer discovery.

### `geography_columns` (VIEW)

Currently returns zero rows. Ready for geography-typed tables if added.

---

## Section 3: Geography Type, Casts, Distance Functions

### `geography` (TYPE)

Identical structure to `geometry`. Signals that distance functions should return meters instead of degrees.

```
If you calculate the distance between Salt Lake City and San Francisco:
- geometry: ST_Distance returns ~7.2 (degrees). Meaningless to a human.
- geography: ST_Distance returns ~956,000 (meters). Immediately useful.
```

### CAST geometry \<-\> geography

Implicit casts in both directions. Internal representation is identical.

### `ST_MakePoint_Geog(lon, lat)` / `ST_MakePolygon_Geog(lon[], lat[])` / `ST_MakeEnvelope_Geog(...)`

Geography constructors.

### `ST_SRID(geography)` / `ST_SetSRID(geography, srid)`

Always returns 4326 / identity.

#### —---- the part below does the same thing to get curved distance on earth from 2 points but with different tricks \---------------------

### `lm__haversine_distance(lon1, lat1, lon2, lat2)` (internal)

Great-circle distance in meters on a perfect sphere (R \= 6,371,000 m). Basically get the curved distance on earth from 2 points.

### `lm__vincenty_distance(lon1, lat1, lon2, lat2)` (internal)

Geodesic distance in meters on the WGS84 ellipsoid. Iterative Vincenty formula. Sub-millimeter accuracy. Falls back to Haversine for near-antipodal points.

Same thing as above but different model. 

### `ST_Distance(geography, geography)`

Haversine great-circle distance in meters. Same thing as above but different type 

### `ST_Distance(geography, geography, use_spheroid)`

Same thing, but configurable. If true: Vincenty. If false: Haversine.

### `ST_DistanceSphere(geography, geography)` / `ST_DistanceSpheroid(geography/geometry)`

Haversine / Vincenty distance in meters.

#### —---------------------------------finishing line----------------------------------------

### `ST_DWithin(geography, geography, distance_m)` / 4-arg version

Within-distance test in meters. Haversine or Vincenty. Basically same thing but try to see if the distance from 2 points is smaller than params

### `ST_Length(geography)` 

"How long is this line?"

### `ST_Perimeter(geography)` 

"How long is the border of this polygon?"

### `ST_Area(geography)`

"How big is this polygon?" via L'Huilier's theorem (square meters).

### `ST_Intersects(geography,geography)` / `ST_Contains(geography,geography)` / `ST_Within(geography,geography)`

Delegate to geometry versions after casting.

### `ST_Envelope(geography)` / `ST_Centroid(geography)`

Delegate to geometry, return geography.

### `ST_X(geography)` / `ST_Y(geography)` / `ST_NPoints(geography)` / `ST_IsEmpty(geography)`

Geography accessors. Return X, Y, how many vertices, and isEmpty. 

### `ST_AsText(geography)` / `ST_AsGeoJSON(geography)` / `ST_AsBinary(geography)`

Geography output — delegate to geometry versions.

Return (1) WKT string, e.g. 'POINT(-111.97 40.52)' (2) GeoJSON string, e.g. '{"type":"Point","coordinates":\[-111.97,40.52\]}' (3) WKB bytes, e.g. \\x0101000000ae47...

### `GeometryType(geography)` / `ST_GeometryType(geography)`

Geography type detection — delegate to geometry versions.

### `ST_GeogFromText(wkt)` / `ST_GeogFromGeoJSON(json)`

Parse WKT/GeoJSON returning geography. returns 'POINT', 'POLYGON', / 'ST\_Point', 'ST\_Polygon' etc., 

### `&&` (OPERATOR: geography, geography) (geography\_overlaps\_bbox)

Bbox overlap / Haversine distance. Backed by geography-specific functions.

### `ST_Extent(geography)` (AGGREGATE)

Delegates to geometry ST\_Extent. (growing box)

### `ST_Project(geography, distance_m, azimuth_rad)`

Forward geodesic projection using Vincenty direct formula on WGS84.

"If I start here and walk X meters in direction Y, where do I end up?"

bookmark 

### Additional geography shims 

// I don’t think this AI summary is correct  
`ST_AsEWKB`, `ST_Force2D`, `ST_Force_2D`, `ST_NDims`, `ST_Transform`, `ST_SimplifyPreserveTopology`, `ST_Simplify`, `ST_Buffer`, `ST_Crosses`, `ST_Overlaps`, `ST_Touches`, `ST_Equals`, `ST_Disjoint` — all delegate to geometry versions.

---

## Section 4: Geohash Functions (20\_GeohashFunctions)

Custom YB functions — not in PostGIS. These power the two-phase geohash query pattern.

### `geohash_encode(lat, lon, precision)`

Encodes coordinates to a geohash string (default precision 10).

### `geohash_adjacent(hash, dir)`

Returns the neighboring geohash cell in direction `n`/`s`/`e`/`w`.

### `geohash_neighbors(hash)`

Returns all 8 surrounding cells as JSONB.

### `geohash_precision_for_miles(miles)`

Returns the highest geohash precision whose cell height fits the given radius.

### `geohash_cell_height_miles(precision)`

Returns cell height in miles for precision 1-10.

### `geohash_move(hash, dir, steps)`

Moves N steps in a cardinal direction.

### `geohash_in_list_within_miles(hash, miles)`

Generates a SQL IN-clause string of all geohash cells covering a given radius.

### `geohash_in_list_within_miles_dir(hash, miles, dirs[])`

Directional version — only expands in specified directions.

### `geohash_decode_bbox(hash)`

Decodes a geohash to its bounding box `(lat_min, lat_max, lon_min, lon_max)`.

### `geohash_decode_bbox_geom(hash)`

Same, but returns the bbox as a polygon geometry.

### `geohash_cell_center(hash)` / `geohash_cell_center_geom(hash)`

Returns the center point of a geohash cell.

### `point_in_polygon(lon, lat, poly_lon[], poly_lat[])`

Ray-casting algorithm. Custom YB function (not in PostGIS).

### `point_in_polygon(point geometry, polygon geometry)`

Geometry overload.

---

## Section 5: Core Geometry Functions (25\_GeometryFunctions)

### `ST_XMin(lon[])` / `ST_XMin(geometry)`

Minimum longitude.

### `ST_XMax(lon[])` / `ST_XMax(geometry)`

Maximum longitude.

### `ST_YMin(lat[])` / `ST_YMin(geometry)`

Minimum latitude.

### `ST_YMax(lat[])` / `ST_YMax(geometry)`

Maximum latitude.

### `ST_Translate(lon[], lat[], dx, dy)` / `ST_Translate(geometry, dx, dy)`

Shifts all vertices by (dx, dy). Array overload returns TABLE.

### `lm__on_segment(...)` / `lm__segments_cross(...)` (internal)

Segment intersection helpers using orientation / cross-product method.

### `ST_Intersects(lon_a[], lat_a[], lon_b[], lat_b[])` / `ST_Intersects(geometry, geometry)`

True if A and B share any space. Tests vertex containment \+ edge crossing.

### `ST_Contains(lon_a[], lat_a[], lon_b[], lat_b[])` / `ST_Contains(geometry, geometry)`

True if A completely contains B and their interiors share at least one point.

---

## Section 6: Tier 1 Geometry Functions (26\_Tier1)

### `ST_X(geometry)` / `ST_Y(geometry)`

Returns longitude / latitude of a point (first vertex).

### `ST_NPoints(geometry)`

Returns number of vertices.

### `GeometryType(geometry)`

Returns `'POINT'`, `'LINESTRING'`, `'POLYGON'`, or `'EMPTY'`.

### `ST_GeometryType(geometry)`

Returns `'ST_Point'`, `'ST_LineString'`, or `'ST_Polygon'`.

### `ST_StartPoint(geometry)` / `ST_EndPoint(geometry)`

First / last vertex as a point geometry.

### `ST_PointN(geometry, n)`

Nth vertex (1-based) as a point.

### `ST_IsClosed(geometry)`

True if first vertex equals last vertex.

### `ST_IsEmpty(geometry)`

True if no vertices.

### `ST_Envelope(geometry)`

Returns the bounding box (2d) as a polygon geometry.

### `ST_MakeLine(a, b)` / `ST_MakeLine(geometry[])`

Creates a linestring from two points or an array of points. (might not be a straight line)

### `ST_Reverse(geometry)`

Reverses vertex order. 

### `ST_FlipCoordinates(geometry)`

Swaps lon and lat.

### `ST_Within(lon_a[], lat_a[], lon_b[], lat_b[])` / `ST_Within(geometry, geometry)`

`ST_Contains` with arguments swapped. If something is inside something. 

### `ST_Disjoint(lon_a[], lat_a[], lon_b[], lat_b[])` / `ST_Disjoint(geometry, geometry)`

"Are they completely separate?"

### `ST_Area(lon[], lat[])` / `ST_Area(geometry)`

Shoelace formula. Returns square degrees (planar). Return the Area

### `ST_Azimuth(geometry, geometry)`

Bearing in radians from A to B, clockwise from north. It return an angle

### `lm__signed_area(lon[], lat[])` (internal)

Signed area. Positive \= CCW, negative \= CW (clockwise). If neither return 0\.

### `ST_IsPolygonCCW(geometry)` / `ST_IsPolygonCW(geometry)`

Tests winding order.

### `ST_ForcePolygonCCW(geometry)` / `ST_ForcePolygonCW(geometry)`

Forces winding order by reversing if needed. If originally not CCW / CW, nothing it returned 

### `ST_Scale(lon[], lat[], sx, sy)` / `ST_Scale(geometry, sx, sy)`

Scales coordinates by factors. (from 0,0)

### `ST_PointInsideCircle(point, cx, cy, r)`

Euclidean point-in-circle test. Boolean

### `ST_AsText(geometry)`

Returns WKT: `POINT(x y)`, `LINESTRING(x1 y1, x2 y2)`, or `POLYGON((x1 y1, ..., x1 y1))`.

### `ST_AsGeoJSON(geometry)`

Returns GeoJSON: `{"type":"Point","coordinates":[x,y]}`.

---

## Section 7: Tier 2 Geometry Functions (27\_Tier2)

### `lm__point_segment_dist(px, py, ax, ay, bx, by)` (internal)

Minimum distance from point to line segment.

### `ST_Distance(geometry, geometry)`

Minimum planar distance (degree units). Computes point-to-point, point-to-segment, and segment-to-segment distances.

Find the shortest distance between any part of shape A and any part of shape B.

### `ST_Length(geometry)`

Planar sum of segment lengths (degrees aka 0\~180 ).  
It adds up the length of each segment in a linestring or polygon outline, in degrees.

### `ST_Perimeter(geometry)`

Closed ring perimeter (degrees).

### `ST_Centroid(geometry)`

Geometric center. Points: identity. Lines: midpoint. Polygons: weighted centroid via shoelace sums.

### `ST_DistanceSphere(geometry, geometry)`

Haversine great-circle distance in meters.

### `ST_DWithin(geometry, geometry, distance)`

True if planar distance \<= threshold.

### `lm__line_total_length(geometry)` (internal)

Total line length for linear referencing.

### `ST_Simplify(geometry, tolerance)` \+ overloads

Douglas-Peucker algorithm. Iterative stack-based implementation.

makes a smooth, detailed shape look rougher to save bandwidth and rendering time when you're too far away to notice the difference. 

```
Before (zoomed in, 12 vertices):
    *---*
   /     \
  *       *---*
  |           |
  *       *---*
   \     /
    *---*

After simplification (zoomed out, 5 vertices):
    *-------*
   /         \
  *           *
   \         /
    *-------*
```

This is supposed to use GEOS library, but we don’t have that (for now)

### `ST_LineInterpolatePoint(geometry, fraction)`

Returns the point at a given fraction (0..1) along a line.

### `ST_LineLocatePoint(line, point)`

Returns the fraction (0..1) of the closest point on the line. (so there will be a T)

### `ST_LineSubstring(geometry, start_frac, end_frac)`

Extracts a sub-line between two fractions.

### `ST_GeomFromText(wkt)`

Parses WKT strings. Supports POINT, LINESTRING, POLYGON (no holes, no multi-geometries).  
basically transfer string to data structures for point, line, and polygon 

### `ST_GeomFromGeoJSON(text)`

Parses GeoJSON Point, LineString, Polygon. Same thing as above but parse JSON

### `ST_Rotate(geometry, angle, cx, cy)`

2D rotation around a center point.

### `ST_Affine(geometry, a, b, d, e, xoff, yoff)`

General 2D affine transform.  
*\--     Applies 2D affine transformation:*  
*\--       x' \= a\*x \+ b\*y \+ xoff*  
*\--       y' \= d\*x \+ e\*y \+ yoff*

### `ST_DumpPoints(geometry)` 

Returns each vertex as `(path integer[], geom geometry)`.

### `ST_DumpSegments(geometry)`

Returns each edge as `(path integer[], geom geometry)`.

```
Polygon with 4 vertices: A → B → C → D

ST_DumpPoints returns 4 rows (the dots):
  {1}  →  A (point)
  {2}  →  B (point)
  {3}  →  C (point)
  {4}  →  D (point)

ST_DumpSegments returns 4 rows (the lines between dots):
  {1}  →  A──B (linestring)
  {2}  →  B──C (linestring)
  {3}  →  C──D (linestring)
  {4}  →  D──A (linestring)  ← closes the ring back to A
```

### `ST_SnapToGrid(geometry, size)`

Rounds coordinates to nearest grid multiple.

### `ST_RemoveRepeatedPoints(geometry, tolerance)`

Removes consecutive duplicate vertices within tolerance.

### `ST_Segmentize(geometry, max_len)`

Subdivides long segments by inserting intermediate vertices. (divided by length)

### `ST_ClipByBox2D(geometry, xmin, ymin, xmax, ymax)` / `ST_ClipByBox2D(geometry, box_geometry)`

Clips polygon to axis-aligned bounding box using Sutherland-Hodgman. It returns the overlap of two shape. 

### `ST_GeneratePoints(geometry, npoints)`

Random points inside a polygon via rejection sampling. 

### `ST_ChaikinSmoothing(geometry, nIterations)`

Corner-cutting smoothing. 

### `ST_Expand(geometry, amount)`

Expands the bounding box by `amount` in all 4 directions.

### `ST_Summary(geometry)`

Text description: geometry type, vertex count, bounding box.

### `ST_AddPoint(geometry, point, position)` / `ST_RemovePoint(geometry, index)` / `ST_SetPoint(geometry, index, point)`

Vertex editing (0-based index).

| Function | What it does |
| :---- | :---- |
| ST\_AddPoint(geom, point, pos) | **Insert** a vertex at position pos. Splices the lon/lat arrays at that index. If pos is omitted (defaults to \-1), appends to the end. |
| ST\_RemovePoint(geom, index) | **Delete** the vertex at index. Concatenates the array slices before and after that index. |
| ST\_SetPoint(geom, index, point) | **Replace** the vertex at index with a new point. Just overwrites lon\[idx\] and lat\[idx\]. |

### `ST_Project(geometry, distance_m, azimuth_rad)`

Forward geodesic projection on the sphere. "If I stand at this point and walk X meters in direction Y, where do I end up?" it’s an Earth (spherical) thing.   
---

## Section 8: Tier 3 Geometry Functions (28\_Tier3)

### `ST_ConvexHull(geometry)`

Graham scan convex hull. (smallest convex polygon that encloses all the points.)  
Convex is a polygon that has no corner that’s \>= 180 degree

### `ST_Intersection(geometry, geometry)`

Sutherland-Hodgman polygon clipping. Exact for convex polygons.

### `ST_Union(geometry, geometry)`

Convex hull of combined vertices. Approximate for non-convex shapes.

### `ST_Difference(geometry, geometry)`

Vertices of A outside B plus intersection points along edges. Exact for convex shapes.

### `ST_SymDifference(geometry, geometry)`

Convex hull of (A\\B union B\\A). Approximate. ST\_Difference(A, B) returns the part of A that is NOT inside B

### `ST_Buffer(geometry, distance_deg, segments)`

Point: generates circular polygon. Polygon: offsets vertices along bisector normals. Approximate.

### `ST_IsValid(geometry)`

Checks for empty arrays, NaN/Inf coordinates, self-intersecting edges, and non-zero area for polygons.

### `ST_Touches(geometry, geometry)`

True if boundaries contact but interiors do not overlap.

### `ST_Crosses(geometry, geometry)`

True if geometries have partial interior intersection at lower dimensions.

| Case | Logic |
| :---- | :---- |
| **Line vs polygon** | Check if the line's endpoints are some inside and some outside the polygon. has\_in AND has\_out \= crosses. |
| **Line vs line** | They intersect at a point but neither fully contains the other. |
| **Polygon vs polygon** | Always returns false — two polygons of the same dimension can't "cross," they "overlap" instead. That's the OGC definition. |

### `ST_Overlaps(geometry, geometry)`

True if same-dimension geometries partially overlap and neither contains the other.

### `ST_Equals(geometry, geometry)`

Topological equality. For polygons: mutual containment. For lines/points: same vertices in any order.

### `ST_Simplify_vw(geometry, area_threshold)`

Visvalingam-Whyatt algorithm. Removes vertices by effective triangle area.(remove dots that doesn’t change the polygon)

---

## Section 9: Geohash Polygon Coverage (30\_GeohashPolygonFunctions)

### `geohash8_fully_within_polygon(hashes[])`

Given 3-5 geohash strings that define polygon vertices, returns all precision-8 cells fully contained within it.

### `geohash8_fully_within_polygon(p1, p2, p3, p4?, p5?)`

Convenience overload accepting individual arguments.

---

## Section 10: Geohash Bbox Functions (31\_GeohashBboxFunctions)

### `geohash_cells_for_bbox(lon_min, lat_min, lon_max, lat_max, precision)`

Enumerates all geohash cells covering a bounding box at the given precision. Core function for the two-phase query pattern.

### `geohash_cells_for_bbox(lon_min, lat_min, lon_max, lat_max)`

Auto-selects precision (5, 6, or 8\) based on bbox size in miles.

### `geohash_cells_for_bbox(numeric, numeric, numeric, numeric, integer)` / `(numeric, numeric, numeric, numeric)`

Numeric overloads for GeoServer JDBC compatibility.

---

## Summary

| Category | Count | Notes |
| :---- | :---- | :---- |
| Real implementations | \~120 | Haversine, Vincenty, Douglas-Peucker, Graham scan, Sutherland-Hodgman, ray casting, WKB/EWKB/TWKB, geohash encode/decode, spherical area |
| Stubs | \~15 | Version strings, SRID=4326, NDims=2, Force2D=identity |
| Shims/wrappers | \~40 | Geography delegates to geometry, numeric overloads, legacy names |
| Types | 3 | geometry, geography, box2d |
| Operators | 3 | `&&`, `<->` (geometry), `<->` (box2d) |
| Aggregates | 2 | ST\_Extent (geometry), ST\_Extent (geography) |
| Casts | 5 | geometry\<-\>geography, geometry\<-\>box2d, geography-\>box2d |

