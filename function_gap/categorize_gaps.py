#!/usr/bin/env python3
"""
Categorize unsupported PostGIS functions into:
  Category 1 — Blocked by external C/C++ library
  Category 2 — Not 2D (3D/4D architectural gap)
  Category 3 — Architectural mismatch (verified reasons)
  (blank)    — Needs manual review

Reads  data/PostGIS-support-functions-result.csv
Writes data/PostGIS-support-functions-analysis.csv
"""

import csv
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CSV_IN = os.path.join(SCRIPT_DIR, "data", "PostGIS-support-functions-result.csv")
CSV_OUT = os.path.join(SCRIPT_DIR, "data", "PostGIS-support-functions-analysis.csv")

# --- Category 1: Blocked by external C/C++ library ---
C_LIBRARY_KEYWORDS = {
    "gml": "libxml2",
    "kml": "libxml2",
    "svg": "libxml2",
    "marc21": "libxml2",
    "mvt": "protobuf-c",
    "geobuf": "protobuf-c",
    "flatgeobuf": "protobuf-c",
    "gdal": "GDAL",
    "raster": "GDAL",
    "srs": "PROJ",
    "transformpipeline": "PROJ",
}

# --- Category 2: Not 2D (3D/4D architectural gap) ---
NOT_2D_CONTAINS = ["3d", "force3", "force4", "hasz", "hasm",
                   "zmax", "zmin", "mmax", "mmin",
                   "trajectory", "cpa"]

# --- Category 3: Architectural mismatch ---

LEGACY_CATALOG_FUNCTIONS = {
    "addgeometrycolumn", "dropgeometrycolumn", "dropgeometrytable",
    "find_srid", "populate_geometry_columns", "updategeometrysrid",
}

CURVE_GEOMETRY_FUNCTIONS = {
    "st_hasarc", "st_numcurves", "st_curven", "st_curvetoline",
    "st_forcecurve", "st_linetocurve", "st_offsetcurve",
}


def extract_name(cell):
    """Pull the function/type name from a CSV cell like 'ST_Foo — description'."""
    if "\u2014" in cell:
        return cell.split("\u2014")[0].strip()
    if " \u2014 " in cell:
        return cell.split(" \u2014 ")[0].strip()
    if " -- " in cell:
        return cell.split(" -- ")[0].strip()
    return ""


def categorize(name):
    """Return (category, reason) or ("", "") if no filter matches."""
    n_lower = name.lower()

    # --- Category 1: Blocked by C/C++ library ---
    for keyword, library in C_LIBRARY_KEYWORDS.items():
        if keyword in n_lower:
            return "Blocked by C/C++ library", library

    # --- Category 2: Not 2D ---
    if name.endswith("ZM"):
        return "Not 2D (3D/4D architectural gap)", "OGC ZM dimension"
    if name.endswith("Z"):
        return "Not 2D (3D/4D architectural gap)", "OGC Z dimension"
    if name.endswith("M"):
        return "Not 2D (3D/4D architectural gap)", "OGC M dimension"

    for kw in NOT_2D_CONTAINS:
        if kw in n_lower:
            return "Not 2D (3D/4D architectural gap)", kw

    # --- Category 3: Architectural mismatch ---

    if n_lower in LEGACY_CATALOG_FUNCTIONS:
        return "Architectural mismatch", "Legacy PostGIS catalog (modern PG uses typmods)"

    if n_lower.startswith("postgis_") or n_lower.startswith("postgis."):
        return "Architectural mismatch", "PostGIS-specific version/config (no C binary to report)"

    if n_lower in CURVE_GEOMETRY_FUNCTIONS:
        return "Architectural mismatch", "Curve geometries (YB type only stores straight-line vertices)"

    if "gidx" in n_lower:
        return "Architectural mismatch", "GiST/BRIN index C-structs (YB uses LSM-trees + geohash)"
    if "box2df" in n_lower and "box2dfrom" not in n_lower:
        return "Architectural mismatch", "GiST/BRIN index C-structs (YB uses LSM-trees + geohash)"

    return "", ""


def main():
    rows_out = []
    cat1 = cat2 = cat3 = blank = 0

    with open(CSV_IN, "r", newline="") as f:
        reader = csv.reader(f)
        header = next(reader)
        header.extend(["Supportability Category", "Blocking Reason"])
        rows_out.append(header)

        for row in reader:
            while len(row) < 3:
                row.append("")

            has_it = row[2].strip()
            name = extract_name(row[1])

            cat, reason = "", ""
            if name and has_it == "No":
                cat, reason = categorize(name)
                if cat.startswith("Blocked"):
                    cat1 += 1
                elif cat.startswith("Not 2D"):
                    cat2 += 1
                elif cat.startswith("Architectural"):
                    cat3 += 1
                else:
                    blank += 1

            row.extend([cat, reason])
            rows_out.append(row)

    with open(CSV_OUT, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerows(rows_out)

    total = cat1 + cat2 + cat3 + blank
    print(f"Categorized {total} unsupported functions:")
    print(f"  Category 1 (Blocked by C/C++ library):  {cat1}")
    print(f"  Category 2 (Not 2D):                    {cat2}")
    print(f"  Category 3 (Architectural mismatch):    {cat3}")
    print(f"  Blank (needs manual review):             {blank}")
    print(f"\nOutput written to: {CSV_OUT}")


if __name__ == "__main__":
    main()
