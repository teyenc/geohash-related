import os
import re
import csv
import subprocess

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GEOTOOLS_POSTGIS_DIR = os.path.join(SCRIPT_DIR, "geotools/modules/plugin/jdbc/jdbc-postgis/src/main/java/org/geotools/data/postgis/")
CSV_PATH = os.path.join(SCRIPT_DIR, "data/PostGIS-support-functions-analysis.csv")

def clone_geotools_if_needed():
    geotools_dir = os.path.join(SCRIPT_DIR, "geotools")
    if not os.path.exists(geotools_dir):
        print("GeoTools repository not found. Cloning (depth=1) to analyze...")
        subprocess.run(["git", "clone", "--depth", "1", "https://github.com/geotools/geotools.git"], cwd=SCRIPT_DIR, check=True)
    else:
        print("GeoTools repository already cloned. Skipping clone.")

def extract_functions_from_java():
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
                    
                    # Match ST_xxx and PostGIS_xxx functions
                    matches = re.findall(r'(?i)\b(ST_[A-Za-z0-9_]+|PostGIS_[A-Za-z0-9_]+)\b', content)
                    for m in matches:
                        found_funcs.add(m.lower())
    
    return found_funcs

def main():
    clone_geotools_if_needed()
    
    geotools_funcs = extract_functions_from_java()
    print(f"Extracted {len(geotools_funcs)} unique ST_/PostGIS_ function names from GeoTools source code.")
    print("Functions:", sorted(list(geotools_funcs)))
    print("-" * 40)
    
    # Read the CSV to see what we support / what is missing
    csv_status = {}
    with open(CSV_PATH, "r") as f:
        reader = csv.reader(f)
        header = next(reader)
        for row in reader:
            if len(row) >= 5:
                name = row[1].split("\u2014")[0].strip() if "\u2014" in row[1] else row[1].split(" ")[0].strip()
                status = row[2]
                cat = row[3]
                csv_status[name.lower()] = (name, status, cat)
    
    supported_called = []
    unsupported_called = []
    unknown_called = []
    
    for gf in geotools_funcs:
        if gf in csv_status:
            name, status, cat = csv_status[gf]
            if status == "Yes":
                supported_called.append(name)
            else:
                unsupported_called.append((name, cat))
        else:
            unknown_called.append(gf)
            
    print(f"GeoServer/GeoTools calls {len(supported_called)} functions we ALREADY SUPPORT:")
    for f in sorted(supported_called):
        print(f"  - {f}")
        
    print(f"\nGeoServer/GeoTools calls {len(unsupported_called)} functions we DO NOT SUPPORT:")
    for f, cat in sorted(unsupported_called):
        print(f"  - {f} (Category: {cat if cat else 'Blank / Uncategorized'})")
        
    print(f"\nGeoServer/GeoTools calls {len(unknown_called)} functions that weren't in our CSV:")
    for f in sorted(unknown_called):
        print(f"  - {f}")

if __name__ == "__main__":
    main()
