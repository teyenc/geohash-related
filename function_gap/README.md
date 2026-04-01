# PostGIS Function Coverage Checker

Checks how many PostGIS functions/types are implemented in the `yb_geospatial` extension.

## Usage

```bash
python check_coverage.py
```

## How it works

1. Parses `yb_geospatial--1.0.sql` to extract all `CREATE FUNCTION/AGGREGATE/TYPE/OPERATOR` names.
2. Reads `data/PostGIS-support-functions.csv` (list of PostGIS functions scraped from the docs).
3. Matches each PostGIS function name against the extension SQL and fills the "Do we have it?" column (`Yes`/`No`).
4. Writes the result to `data/PostGIS-support-functions-result.csv` and prints a coverage summary.

## Files

| File | Description |
|------|-------------|
| `check_coverage.py` | Main script |
| `data/PostGIS-support-functions.csv` | Input — PostGIS function list |
| `data/PostGIS-support-functions-result.csv` | Output — with coverage column filled |
