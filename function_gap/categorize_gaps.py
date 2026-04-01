#!/usr/bin/env python3
"""
Categorize unsupported PostGIS functions into:
  Category 1 — Blocked by external C/C++ library
  Category 2 — Not 2D (3D/4D architectural gap)
  (blank)    — Needs manual review

Reads  data/PostGIS-support-functions-result.csv
Writes data/PostGIS-support-functions-analysis.csv
"""

import csv
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CSV_IN = os.path.join(SCRIPT_DIR, "data", "PostGIS-support-functions-result.csv")
CSV_OUT = os.path.join(SCRIPT_DIR, "data", "PostGIS-support-functions-analysis.csv")

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

NOT_2D_CONTAINS = ["3d", "force3", "force4", "hasz", "hasm",
                   "zmax", "zmin", "mmax", "mmin",
                   "trajectory", "cpa"]


def extract_name(cell):
    """Pull the function/type name from a CSV cell like 'ST_Foo — description'."""
    if "\u2014" in cell:
        return cell.split("\u2014")[0].strip()
    if " — " in cell:
        return cell.split(" — ")[0].strip()
    if " -- " in cell:
        return cell.split(" -- ")[0].strip()
    return ""


def categorize(name):
    """Return (category, reason) or ("", "") if no filter matches."""
    n_lower = name.lower()

    for keyword, library in C_LIBRARY_KEYWORDS.items():
        if keyword in n_lower:
            return "Blocked by C/C++ library", library

    if name.endswith("ZM") or name.endswith("Z") or name.endswith("M"):
        if not name.endswith("ZM"):
            last = name[-1]
        else:
            last = "ZM"
        if last in ("Z", "M", "ZM"):
            return "Not 2D (3D/4D architectural gap)", f"OGC {last} dimension"

    for kw in NOT_2D_CONTAINS:
        if kw in n_lower:
            return "Not 2D (3D/4D architectural gap)", kw

    return "", ""


def main():
    rows_out = []
    cat1 = cat2 = blank = 0

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
                else:
                    blank += 1

            row.extend([cat, reason])
            rows_out.append(row)

    with open(CSV_OUT, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerows(rows_out)

    total = cat1 + cat2 + blank
    print(f"Categorized {total} unsupported functions:")
    print(f"  Category 1 (Blocked by C/C++ library): {cat1}")
    print(f"  Category 2 (Not 2D):                   {cat2}")
    print(f"  Blank (needs manual review):            {blank}")
    print(f"\nOutput written to: {CSV_OUT}")


if __name__ == "__main__":
    main()
