#!/usr/bin/env python3
"""
Cross-reference GeoServer/GeoTools PostGIS dialect against the actual
yb_geospatial SQL file to determine which functions GeoServer needs
and whether we already implement them.

This is a separate analysis from the PostGIS CSV gap analysis.
It checks the SQL file directly, not the CSV.
"""

import os
import re
import subprocess

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GEOTOOLS_POSTGIS_DIR = os.path.join(
    SCRIPT_DIR,
    "geotools", "modules", "plugin", "jdbc", "jdbc-postgis",
    "src", "main", "java", "org", "geotools", "data", "postgis",
)
SQL_PATH = os.path.join(
    SCRIPT_DIR, "..", "..",
    "yugabyte-db", "src", "postgres", "yb-extensions",
    "yb_geospatial", "yb_geospatial--1.0.sql",
)


def clone_geotools_if_needed():
    geotools_dir = os.path.join(SCRIPT_DIR, "geotools")
    if not os.path.exists(geotools_dir):
        print("GeoTools repository not found. Cloning (depth=1) to analyze...")
        subprocess.run(
            ["git", "clone", "--depth", "1",
             "https://github.com/geotools/geotools.git"],
            cwd=SCRIPT_DIR, check=True,
        )
    else:
        print("GeoTools repository already cloned. Skipping clone.")


def extract_functions_from_java():
    """Extract all ST_/PostGIS_ function names referenced in the GeoTools PostGIS dialect."""
    found_funcs = set()

    if not os.path.exists(GEOTOOLS_POSTGIS_DIR):
        print(f"Directory not found: {GEOTOOLS_POSTGIS_DIR}")
        return found_funcs

    for root, dirs, files in os.walk(GEOTOOLS_POSTGIS_DIR):
        for file in files:
            if file.endswith(".java"):
                filepath = os.path.join(root, file)
                with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
                    content = f.read()

                matches = re.findall(
                    r'(?i)\b(ST_[A-Za-z0-9_]+|PostGIS_[A-Za-z0-9_]+)\b',
                    content,
                )
                for m in matches:
                    found_funcs.add(m.lower())

    return found_funcs


def extract_functions_from_sql(sql_path):
    """Extract all function/aggregate/type/operator names defined in the extension SQL."""
    defined = set()

    if not os.path.exists(sql_path):
        print(f"SQL file not found: {sql_path}")
        return defined

    with open(sql_path, "r") as f:
        sql = f.read()

    for m in re.finditer(
        r"(?i)CREATE\s+(?:OR\s+REPLACE\s+)?(?:FUNCTION|AGGREGATE)\s+(\w+)", sql
    ):
        defined.add(m.group(1).lower())
    for m in re.finditer(r"(?i)CREATE\s+TYPE\s+(\w+)", sql):
        defined.add(m.group(1).lower())
    for m in re.finditer(r"(?i)CREATE\s+OPERATOR\s+(\S+)", sql):
        defined.add(m.group(1).lower())

    return defined


def main():
    clone_geotools_if_needed()

    geotools_funcs = extract_functions_from_java()
    print(f"\nExtracted {len(geotools_funcs)} unique ST_/PostGIS_ function names from GeoTools source.")
    print("Functions:", sorted(geotools_funcs))
    print("-" * 60)

    sql_defined = extract_functions_from_sql(SQL_PATH)
    print(f"Extracted {len(sql_defined)} unique names from yb_geospatial SQL file.")
    print("-" * 60)

    supported = []
    not_supported = []

    for gf in sorted(geotools_funcs):
        if gf in sql_defined:
            supported.append(gf)
        else:
            not_supported.append(gf)

    print(f"\nGeoServer/GeoTools calls {len(supported)} functions we IMPLEMENT in yb_geospatial:")
    for f in supported:
        print(f"  [YES] {f}")

    print(f"\nGeoServer/GeoTools calls {len(not_supported)} functions we DO NOT IMPLEMENT:")
    for f in not_supported:
        print(f"  [NO]  {f}")

    print(f"\n--- Summary ---")
    print(f"  GeoTools requires:  {len(geotools_funcs)} functions")
    print(f"  We implement:       {len(supported)}")
    print(f"  We are missing:     {len(not_supported)}")
    if geotools_funcs:
        print(f"  Coverage:           {100 * len(supported) / len(geotools_funcs):.1f}%")


if __name__ == "__main__":
    main()
