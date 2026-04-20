# Visualizations

Static and interactive diagrams built while exploring geohash / S2 / GIN spatial indexing for YugabyteDB.

Open `.html` files in a browser (or Cursor's canvas). `.png` files are static exports — usually there's a matching `.html` in the same folder if you want to play with it.

## `geohash_problems/` — why geohash doesn't scale

| file | what it shows |
|---|---|
| `bbox_vs_geohash.png` | why a bounding-box query needs multiple geohash ranges |
| `geohash_vs_bbox.png` | same story, different framing |
| `geohash_knn_far_away.png` | k-NN fails when the nearest neighbor sits across a Z-curve cell boundary |
| `geohash_line_intersect_problem.png` | a long line (river) spans many geohash cells at any precision |
| `geohash_line_problem_minimal.png` | minimal reproduction of the same issue |

## `geohash_pipeline/` — how a geohash query actually flows

| file | what it shows |
|---|---|
| `geohash_polygon_pipeline_static.html` | static snapshot of the polygon-cover pipeline |
| `geohash_polygon_pipeline.png` | PNG export of the same |

## `s2_internals/` — what S2 does differently

| file | what it shows |
|---|---|
| `s2_quad_tree_grid.png` | S2 cube-face quad tree at different levels |
| `s2_quadtree_hierarchy.png` | parent/child cell relationships |
| `s2_quad_tree_expansion.png` | how a covering expands recursively |
| `s2_mixed_levels.png` | cells of different levels coexisting in one covering |
| `s2_gin_write_path.png` | insert-time flow: geometry → S2 cover → mapping table |
| `s2_gin_pipeline.png` | query-time flow: polygon → cover → BETWEEN range scans |
| `s2_gin_index_interactive.html` | interactive version of the above |

Note: the filenames say "gin" for historical reasons — an earlier prototype used a GIN index before we migrated to the B-tree mapping-table pattern. The content is still accurate for the current `yb_geospatial_s2` extension.

## `gin_indexing/` — GIN and ybgin architecture

| file | what it shows |
|---|---|
| `gin_inverted_index.png` | standard PostgreSQL GIN layout (term → posting list) |
| `gin_parent_expansion.png` | why inverted indexes need parent expansion for prefix trees |
| `ybgin_architecture.png` | how YB implements GIN across tablets |
| `ybgin_interactive.html` | interactive version |

## `misc/`

| file | what it shows |
|---|---|
| `rtree_visualization.html` | PostGIS R-tree / GiST bounding-box hierarchy |

## See also (separate folders, not under `visualizations/`)

- `../s2_range_scan/` — newer visualizations of the BETWEEN + ancestor lookup pattern for the `yb_geospatial_s2` extension (Hilbert vs Z-order, B-tree range scan walkthrough, mixed-level B+ tree).
- `../s2_vs_geohash_benchmark/` — quantitative comparison (PostGIS vs Dan's geohash vs S2) with Q1–Q4 latency/correctness measurements.
