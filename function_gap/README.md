# PostGIS Function Gap Analysis

This directory contains tools and scripts used to analyze the gap between the full PostGIS API and the `yb_geospatial` extension for YugabyteDB. It includes data categorization based on structural limitations and cross-referencing against real-world usage (e.g., GeoServer/GeoTools).

## Files and Scripts

### 1. `data/PostGIS-support-functions-result.csv`
The original, un-categorized list of ~370 PostGIS functions, marking whether the current `yb_geospatial` extension supports them ("Yes" or "No").

### 2. `categorize_gaps.py`
A Python script that analyzes the missing ("No") functions and categorizes them into structural buckets based on the extension's pure-SQL architecture. It produces a new CSV with the analysis.

**Categories applied:**
- **Category 1: Blocked by C/C++ library**: PostGIS relies on massive external compiled libraries (e.g., `libxml2`, `GDAL`, `PROJ`, `protobuf-c`). Since `yb_geospatial` is a pure PL/pgSQL extension, any function wrapping these libraries physically cannot be implemented.
- **Category 2: Not 2D (3D/4D architectural gap)**: The `geometry` composite type in YB strictly uses `lon[]` and `lat[]` arrays. PostGIS functions demanding an elevation (`Z`) or measure/time (`M`) dimension are structurally incompatible.
- **Category 3: Architectural mismatch**: Functions that assume internal PostgreSQL C-structures that YB does not use. For example:
  - Legacy PostGIS catalog tracking (`geometry_columns` table vs modern native typmods).
  - GiST index float-precision structs (`box2df`, `gidx`), which are irrelevant because YB uses LSM-trees + geohashing instead of GiST R-trees.
  - Curve geometries (circular arcs), which aren't supported by our straight-line vertex arrays.

**To run:**
```bash
python3 categorize_gaps.py
```
Outputs to `data/PostGIS-support-functions-analysis.csv`.

### 3. `analyze_geotools.py`
A Python script designed to answer the practical question: *"Out of all the missing functions, which ones does a real-world application like GeoServer actually care about?"*

The script automatically downloads the **GeoTools** source code (the Java mapping engine behind GeoServer). It parses the Java files in the `jdbc-postgis` dialect to extract every exact `ST_` and `PostGIS_` function call GeoServer executes. It then cross-references those calls against our support CSV.

**To run:**
```bash
python3 analyze_geotools.py
```
*(Note: If the `geotools` directory does not exist, the script will automatically run `git clone --depth 1 https://github.com/geotools/geotools.git` before analyzing).*

---

## Key Findings

Through this analysis, we confirmed that while `yb_geospatial` lacks over 200 functions found in PostGIS, **almost all missing functions are either fundamentally blocked by C/C++ dependencies or architectural choices (like abandoning GiST for LSM-trees).** 

More importantly, when scanning the GeoTools PostGIS dialect, we found that **YugabyteDB already supports 32 out of the 33 spatial functions required by GeoServer**. The only gap (`ST_HasArc`) is bypassed entirely when dealing with straight-line shapes.