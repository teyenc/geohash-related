#!/usr/bin/env python3
"""
Parse yb_geospatial--1.0.sql, cross-reference PostGIS functions and Dan's
analysis notes, then output a consolidated CSV report.
"""

import csv
import re
import sys
from pathlib import Path

SQL_PATH = Path(__file__).resolve().parent.parent.parent.parent / \
    "yugabyte-db/src/postgres/yb-extensions/yb_geospatial/yb_geospatial--1.0.sql"
POSTGIS_CSV_PATH = Path(__file__).resolve().parent.parent / "data/PostGIS-support-functions.csv"
ANALYSIS_MD_PATH = Path(__file__).resolve().parent / "Dan's code analysis.md"
OUTPUT_CSV_PATH = Path(__file__).resolve().parent / "yb_geospatial_report.csv"


def extract_definitions(sql_text):
    """Extract all CREATE statements with their sections and line numbers."""
    lines = sql_text.split("\n")
    entries = []
    current_section = "Section 1: Geometry Type, Constructors, WKB/EWKB/TWKB, Operators"

    section_re = re.compile(
        r"^--\s*Section\s+(\d+):\s*(.+)", re.IGNORECASE
    )

    i = 0
    while i < len(lines):
        line = lines[i]

        # Track section changes
        m = section_re.match(line.strip())
        if m:
            current_section = f"Section {m.group(1)}: {m.group(2).strip()}"
            i += 1
            continue

        stripped = line.strip().upper()

        # ---- CREATE TYPE ----
        if stripped.startswith("CREATE TYPE") and "AS" in stripped:
            raw = line.strip()
            type_m = re.match(r"CREATE\s+TYPE\s+(\w+)", raw, re.IGNORECASE)
            if type_m:
                entries.append({
                    "name": type_m.group(1),
                    "signature": f"{type_m.group(1)} (TYPE)",
                    "kind": "TYPE",
                    "section": current_section,
                    "line": i + 1,
                })
            i += 1
            continue

        # ---- CREATE OPERATOR ----
        if stripped.startswith("CREATE OPERATOR"):
            raw = line.strip()
            op_m = re.match(r"CREATE\s+OPERATOR\s+(.+?)\s*\(", raw, re.IGNORECASE)
            if op_m:
                op_sym = op_m.group(1).strip()
                # Read the next few lines to get LEFTARG/RIGHTARG
                block = raw
                j = i + 1
                while j < len(lines) and ");" not in lines[j]:
                    block += " " + lines[j].strip()
                    j += 1
                if j < len(lines):
                    block += " " + lines[j].strip()

                left_m = re.search(r"LEFTARG\s*=\s*(\w+)", block, re.IGNORECASE)
                right_m = re.search(r"RIGHTARG\s*=\s*(\w+)", block, re.IGNORECASE)
                left_t = left_m.group(1) if left_m else "?"
                right_t = right_m.group(1) if right_m else "?"

                entries.append({
                    "name": op_sym,
                    "signature": f"{op_sym} (OPERATOR: {left_t}, {right_t})",
                    "kind": "OPERATOR",
                    "section": current_section,
                    "line": i + 1,
                })
            i += 1
            continue

        # ---- CREATE AGGREGATE ----
        if stripped.startswith("CREATE AGGREGATE"):
            raw = line.strip()
            agg_m = re.match(r"CREATE\s+AGGREGATE\s+(\w+)\s*\((.+?)\)", raw, re.IGNORECASE)
            if agg_m:
                entries.append({
                    "name": agg_m.group(1),
                    "signature": f"{agg_m.group(1)}({agg_m.group(2).strip()}) (AGGREGATE)",
                    "kind": "AGGREGATE",
                    "section": current_section,
                    "line": i + 1,
                })
            i += 1
            continue

        # ---- CREATE CAST ----
        if stripped.startswith("CREATE CAST"):
            raw = line.strip()
            cast_m = re.match(r"CREATE\s+CAST\s*\(\s*(\w+)\s+AS\s+(\w+)\s*\)", raw, re.IGNORECASE)
            if cast_m:
                entries.append({
                    "name": f"CAST ({cast_m.group(1)} AS {cast_m.group(2)})",
                    "signature": f"CAST ({cast_m.group(1)} AS {cast_m.group(2)})",
                    "kind": "CAST",
                    "section": current_section,
                    "line": i + 1,
                })
            i += 1
            continue

        # ---- CREATE OR REPLACE FUNCTION ----
        if stripped.startswith("CREATE OR REPLACE FUNCTION"):
            # Collect lines until we hit RETURNS or AS $$
            func_block = line.strip()
            j = i + 1
            while j < len(lines):
                next_line = lines[j].strip()
                if next_line.upper().startswith("RETURNS"):
                    break
                func_block += " " + next_line
                j += 1

            # Parse function name and params
            func_m = re.match(
                r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+(\w+)\s*\((.*)\)",
                func_block, re.IGNORECASE | re.DOTALL
            )
            if not func_m:
                # Try without closing paren (multi-line)
                func_m = re.match(
                    r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+(\w+)\s*\((.*)",
                    func_block, re.IGNORECASE | re.DOTALL
                )

            if func_m:
                fname = func_m.group(1)
                raw_params = func_m.group(2).strip()
                # Clean up params
                raw_params = re.sub(r"\s+", " ", raw_params)
                raw_params = raw_params.rstrip(")")

                entries.append({
                    "name": fname,
                    "signature": f"{fname}({raw_params})",
                    "kind": "FUNCTION",
                    "section": current_section,
                    "line": i + 1,
                })
            i += 1
            continue

        i += 1

    return entries


def load_postgis_functions(csv_path):
    """Load PostGIS function names from the CSV."""
    names = set()
    with open(csv_path, "r", encoding="utf-8") as f:
        reader = csv.reader(f)
        for row in reader:
            if len(row) >= 2:
                cell = row[1].strip()
                # Extract function/type name before the " —" dash
                m = re.match(r"([\w_<>]+(?:\s*\([^)]*\))?)\s*[—–-]", cell)
                if m:
                    raw = m.group(1).strip()
                    # Normalize: take just the name part
                    name_only = re.match(r"(\w+)", raw)
                    if name_only:
                        names.add(name_only.group(1).lower())
    return names


def load_analysis_notes(md_path):
    """
    Parse Dan's analysis markdown and return a dict:
        lowercase_name -> (note_text, support_level)
    """
    notes = {}
    with open(md_path, "r", encoding="utf-8") as f:
        text = f.read()

    # Split into heading blocks
    blocks = re.split(r"^###\s+", text, flags=re.MULTILINE)

    for block in blocks[1:]:  # skip preamble
        first_line, _, body = block.partition("\n")
        first_line = first_line.strip()

        # Extract the backtick-quoted name(s)
        names_in_heading = re.findall(r"`([^`]+)`", first_line)
        # Also handle non-backtick operator headings like: && (OPERATOR: ...)
        if not names_in_heading:
            op_m = re.match(r"(&&|<->|<#>|~=|~)", first_line)
            if op_m:
                names_in_heading = [op_m.group(1)]

        # Get note text (first meaningful paragraph)
        body = body.strip()
        # Remove code blocks for note extraction
        clean_body = re.sub(r"```[\s\S]*?```", "", body).strip()
        # Take first paragraph
        paragraphs = [p.strip() for p in clean_body.split("\n\n") if p.strip()]
        note = paragraphs[0] if paragraphs else ""
        # Collapse to single line
        note = re.sub(r"\s+", " ", note).strip()
        # Truncate long notes
        if len(note) > 300:
            note = note[:297] + "..."

        # Determine support level from note content + heading hints
        support = determine_support_level(first_line, note, body)

        for raw_name in names_in_heading:
            # Extract the base function name
            base = re.match(r"(\w+)", raw_name)
            if base:
                key = base.group(1).lower()
                # Don't overwrite a more specific entry with a less specific one
                if key not in notes:
                    notes[key] = (note, support)
            # Also store full raw name for operators
            notes[raw_name.lower()] = (note, support)

    return notes


def determine_support_level(heading, note, body):
    """Heuristic to classify support level."""
    combined = (heading + " " + note + " " + body).lower()

    if "(internal)" in heading.lower():
        return "Internal Helper"

    if "(stub)" in combined or "stub" in combined:
        return "Stub"
    if "shim" in combined:
        return "Shim"
    if "delegate" in combined and "geometry version" in combined:
        return "Shim"
    if "delegate" in combined:
        return "Shim"
    if "identity" in combined and ("always" in combined or "return" in combined):
        return "Stub"
    if "returns null" in combined and "not available" in combined:
        return "Stub"
    if "(type)" in heading.lower() or "(aggregate)" in heading.lower():
        return "Fully Supported"

    return "Fully Supported"


def match_postgis(name, kind, postgis_names):
    """Check if this definition corresponds to a PostGIS function."""
    normalized = name.lower()

    # Custom YB functions that are NOT in PostGIS
    yb_custom = {
        "geohash_encode", "geohash_adjacent", "geohash_neighbors",
        "geohash_precision_for_miles", "geohash_cell_height_miles",
        "geohash_move", "geohash_in_list_within_miles",
        "geohash_in_list_within_miles_dir", "geohash_decode_bbox",
        "geohash_decode_bbox_geom", "geohash_cell_center",
        "geohash_cell_center_geom", "point_in_polygon",
        "geohash8_fully_within_polygon", "geohash_cells_for_bbox",
    }
    if normalized in yb_custom:
        return "No (YB custom)"

    # Internal helpers
    if normalized.startswith("lm__"):
        return "No (internal helper)"

    # Backing functions for operators
    if normalized in ("geometry_overlaps_bbox", "geometry_distance",
                      "box2d_distance", "geography_overlaps_bbox",
                      "geography_distance"):
        return "No (operator backing fn)"

    if kind == "CAST":
        return "No (YB infrastructure)"

    # Check against PostGIS list
    if normalized in postgis_names:
        return "Yes"

    # Some names with underscores might match
    no_underscore = normalized.replace("_", "")
    for pg_name in postgis_names:
        if pg_name.replace("_", "") == no_underscore:
            return "Yes"

    # Known PostGIS matches that might not match by simple name lookup
    known_postgis = {
        "st_makepoint", "st_makepolygon", "st_makeenvelope", "st_srid",
        "st_setsrid", "st_transform", "st_asbinary", "st_asewkb",
        "st_force2d", "st_force_2d", "st_ndims", "st_geomfromtext",
        "st_geomfromwkb", "st_estimatedextent", "st_estimated_extent",
        "st_simplifypreservetopology", "st_astwkb", "st_x", "st_y",
        "st_npoints", "st_geometrytype", "geometrytype",
        "st_startpoint", "st_endpoint", "st_pointn", "st_isclosed",
        "st_isempty", "st_envelope", "st_makeline", "st_reverse",
        "st_flipcoordinates", "st_within", "st_disjoint", "st_area",
        "st_azimuth", "st_ispolygonccw", "st_ispolygoncw",
        "st_forcepolygonccw", "st_forcepolygoncw", "st_scale",
        "st_pointinsidecircle", "st_astext", "st_asgeojson",
        "st_distance", "st_length", "st_perimeter", "st_centroid",
        "st_distancesphere", "st_dwithin", "st_simplify",
        "st_lineinterpolatepoint", "st_linelocatepoint",
        "st_linesubstring", "st_geomfromgeojson", "st_rotate",
        "st_affine", "st_dumppoints", "st_dumpsegments",
        "st_snaptogrid", "st_removerepeatedpoints", "st_segmentize",
        "st_clipbybox2d", "st_generatepoints", "st_chaikinsmoothing",
        "st_expand", "st_summary", "st_addpoint", "st_removepoint",
        "st_setpoint", "st_project", "st_convexhull", "st_intersection",
        "st_union", "st_difference", "st_symdifference", "st_buffer",
        "st_isvalid", "st_touches", "st_crosses", "st_overlaps",
        "st_equals", "st_simplify_vw", "st_simplifyvw",
        "st_contains", "st_intersects", "st_translate",
        "st_xmin", "st_xmax", "st_ymin", "st_ymax",
        "st_distancespheroid", "st_geogfromtext", "st_geogfromgeojson",
        "st_makepoint_geog", "st_makepolygon_geog", "st_makeenvelope_geog",
        "postgis_version", "postgis_lib_version", "postgis_full_version",
        "postgis_geos_version",
    }

    if normalized in known_postgis:
        return "Yes"

    # PostGIS version stubs
    if normalized.startswith("postgis_"):
        return "Yes"

    # Geography wrappers for known PostGIS functions
    if normalized.startswith("st_") and normalized not in yb_custom:
        return "Yes"

    if kind in ("TYPE", "OPERATOR", "AGGREGATE"):
        if normalized in ("geometry", "geography", "box2d"):
            return "Yes"
        if "&&" in name or "<->" in name:
            return "Yes"
        if "st_extent" in normalized:
            return "Yes"

    return "No"


def classify_support(entry, analysis_notes):
    """Determine support level for an entry."""
    name_lower = entry["name"].lower()
    kind = entry["kind"]
    sig_lower = entry["signature"].lower()

    # Internal helpers — always "Internal Helper"
    if name_lower.startswith("lm__"):
        return "Internal Helper"
    if name_lower in ("geometry_overlaps_bbox", "geometry_distance",
                       "box2d_distance", "geography_overlaps_bbox",
                       "geography_distance"):
        return "Internal Helper"

    # Types, Casts, Aggregates, Operators — always "Fully Supported"
    if kind in ("TYPE", "CAST", "AGGREGATE", "OPERATOR"):
        return "Fully Supported"

    # Hard-coded stubs (always return fixed values / identity regardless of input)
    stubs = {
        "postgis_version", "postgis_lib_version", "postgis_full_version",
        "postgis_geos_version",
        "st_srid", "st_setsrid", "st_transform",
        "st_force2d", "st_force_2d", "st_ndims",
    }
    if name_lower in stubs:
        return "Stub"

    # Shims: delegate to another function with minimal logic
    shims = {"st_simplifypreservetopology", "st_estimated_extent"}
    if name_lower in shims:
        return "Shim"

    # Geography section: classify based on what the function actually does
    section = entry["section"].lower()
    if "geography" in section:
        # Functions with real math / their own implementation
        geo_full = {
            "lm__haversine_distance", "lm__vincenty_distance",
            "st_distance", "st_length", "st_perimeter", "st_area",
            "st_project",
        }
        if name_lower in geo_full:
            return "Fully Supported"
        # Constructors are full implementations
        if "makepoint" in name_lower or "makepolygon" in name_lower or "makeenvelope" in name_lower:
            return "Fully Supported"
        # Stubs in geography context too
        if name_lower in stubs:
            return "Stub"
        # Everything else in geography section delegates to geometry
        return "Shim"

    # Check analysis notes for remaining functions
    if name_lower in analysis_notes:
        _, support = analysis_notes[name_lower]
        if support != "Fully Supported":
            return support

    return "Fully Supported"


def get_note(entry, analysis_notes):
    """Get a note for the entry from the analysis doc."""
    name_lower = entry["name"].lower()
    kind = entry["kind"]

    if name_lower in analysis_notes:
        note, _ = analysis_notes[name_lower]
        return note

    # Fallback notes for common patterns
    if name_lower.startswith("lm__"):
        return "Internal helper function"
    if kind == "CAST":
        return "Implicit cast between types"
    if kind == "OPERATOR":
        return ""
    if kind == "TYPE":
        return ""

    return ""


def main():
    sql_text = SQL_PATH.read_text(encoding="utf-8")
    entries = extract_definitions(sql_text)
    print(f"Extracted {len(entries)} definitions from SQL")

    postgis_names = load_postgis_functions(POSTGIS_CSV_PATH)
    print(f"Loaded {len(postgis_names)} PostGIS function names")

    analysis_notes = load_analysis_notes(ANALYSIS_MD_PATH)
    print(f"Loaded {len(analysis_notes)} analysis note entries")

    rows = []
    for entry in entries:
        postgis_status = match_postgis(entry["name"], entry["kind"], postgis_names)
        support = classify_support(entry, analysis_notes)
        note = get_note(entry, analysis_notes)
        rows.append({
            "Function name (including params)": entry["signature"],
            "Section": entry["section"],
            "Is it on PostGIS function": postgis_status,
            "Note": note,
            "Support level": support,
        })

    with open(OUTPUT_CSV_PATH, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "Function name (including params)",
            "Section",
            "Is it on PostGIS function",
            "Note",
            "Support level",
        ])
        writer.writeheader()
        writer.writerows(rows)

    print(f"Wrote {len(rows)} rows to {OUTPUT_CSV_PATH}")

    # Print summary
    kinds = {}
    supports = {}
    for entry in entries:
        kinds[entry["kind"]] = kinds.get(entry["kind"], 0) + 1
    for row in rows:
        s = row["Support level"]
        supports[s] = supports.get(s, 0) + 1
    print(f"\nBy kind: {kinds}")
    print(f"By support: {supports}")


if __name__ == "__main__":
    main()
