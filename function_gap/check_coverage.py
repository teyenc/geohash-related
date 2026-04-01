#!/usr/bin/env python3
"""
Check which PostGIS functions from the CSV are implemented in yb_geospatial.
Outputs a new CSV with the "Do we have it?" column filled in.
"""

import csv
import re
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CSV_IN = os.path.join(SCRIPT_DIR, "data", "PostGIS-support-functions.csv")
CSV_OUT = os.path.join(SCRIPT_DIR, "data", "PostGIS-support-functions-result.csv")
SQL_PATH = os.path.join(
    SCRIPT_DIR, "..", "..",
    "yugabyte-db", "src", "postgres", "yb-extensions",
    "yb_geospatial", "yb_geospatial--1.0.sql",
)


def get_defined_names(sql_path):
    """Extract all names defined via CREATE FUNCTION/AGGREGATE/TYPE/OPERATOR in the SQL."""
    with open(sql_path, "r") as f:
        sql = f.read()

    names = set()
    for m in re.finditer(
        r"CREATE\s+(?:OR\s+REPLACE\s+)?(?:FUNCTION|AGGREGATE)\s+(\w+)",
        sql,
        re.IGNORECASE,
    ):
        names.add(m.group(1).lower())
    for m in re.finditer(r"CREATE\s+TYPE\s+(\w+)", sql, re.IGNORECASE):
        names.add(m.group(1).lower())
    for m in re.finditer(r"CREATE\s+OPERATOR\s+(\S+)", sql, re.IGNORECASE):
        names.add(m.group(1).lower())
    return names


def extract_name(cell):
    """Pull the function/type name from a CSV cell like 'ST_Foo — description'."""
    if "\u2014" in cell:          # em-dash
        return cell.split("\u2014")[0].strip()
    if " — " in cell:            # spaced em-dash (some editors)
        return cell.split(" — ")[0].strip()
    if " -- " in cell:           # double-hyphen fallback
        return cell.split(" -- ")[0].strip()
    return ""


def main():
    defined = get_defined_names(SQL_PATH)

    rows_out = []
    found_count = 0
    total_count = 0

    with open(CSV_IN, "r", newline="") as f:
        reader = csv.reader(f)
        header = next(reader)
        rows_out.append(header)            # keep original header as-is

        for row in reader:
            while len(row) < 3:
                row.append("")

            cell = row[1].strip()
            name = extract_name(cell)

            if name:
                total_count += 1
                if name.lower() in defined:
                    row[2] = "Yes"
                    found_count += 1
                else:
                    row[2] = "No"
            # else: section header row — leave col 2 blank

            rows_out.append(row)

    with open(CSV_OUT, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerows(rows_out)

    print(f"Checked {total_count} PostGIS functions/types against extension SQL.")
    print(f"  Found:   {found_count}")
    print(f"  Missing: {total_count - found_count}")
    print(f"  Coverage: {100 * found_count / total_count:.1f}%")
    print(f"\nOutput written to: {CSV_OUT}")


if __name__ == "__main__":
    main()
