"""
Per-run metadata writer.

Both latency_sweep.py and cell_count_sweep.py call write_metadata() at
the end of main() so every results/run_<ts>/ folder has a metadata.json
recording the exact knobs that produced the CSV — shape (box/circle),
envelope size, radius, sample grid, engine cover-level params, etc.

That lets someone reading the CSV/PNGs months later know exactly what
the run measured, without having to git-blame the sweep script.

The schema:
  {
    "script": "latency_sweep.py" | "cell_count_sweep.py",
    "timestamp_utc": "<iso8601>",
    "shape": "box" | "circle",         # latency_sweep only; cell_count is
                                       # always "box" (envelope-as-input)
    "envelope": {
      "side_km": 50,
      "radius_km": 25 | null           # null when shape != "circle"
    },
    "sampling": {
      "latitudes": [...],
      "longitudes": [...],
      "warmup_runs": 1,                # latency_sweep only
      "measured_runs": 2,              # latency_sweep only
      "queries_total": N,
    },
    "engines": ["c_geohash", "s2", ...],
    "engine_params": {
      "<engine>": { ... per-engine level/precision knobs ... }
    },
    "data": {
      "table": "my_mapdata",
      "rows": 344688
    },
    "outputs": {
      "csv": "<filename>",
      "raw": "<filename>" | null       # raw transcript exists only for
                                       # latency_sweep
    }
  }
"""
import json
import os
import time

# Centralized engine-param table — imported by both sweep scripts. Keep in
# sync with the constants in sweep_queries.py / cell_count_sweep.py.
def collect_engine_params(engines, kind):
    """Return a dict of {engine_name: {param: value}} for the requested
    `engines`. `kind` is 'latency' (uses sweep_queries' adaptive ranges) or
    'cell_count' (uses cell_count_sweep's wider adaptive ranges)."""
    import sweep_queries as Q
    if kind == 'latency':
        all_params = {
            'pure_sql':  {'gh_pure_prec': Q.GH_PURE_PREC},
            'c_geohash': {'gh_adapt_min': Q.GH_ADAPT_MIN,
                          'gh_adapt_max': Q.GH_ADAPT_MAX},
            'qz':        {'qz_adapt_min': 5,       # hardcoded inside helper
                          'qz_adapt_max': Q.QZ_ADAPT_MAX},
            's2':        {'s2_adapt_min': Q.S2_ADAPT_MIN,
                          's2_adapt_max': Q.S2_ADAPT_MAX,
                          's2_max_cells': Q.S2_MAX_CELLS},
        }
    elif kind == 'cell_count':
        import cell_count_sweep as C
        all_params = {
            'gh': {'min_prec': C.GH_MIN_PREC, 'max_prec': C.GH_MAX_PREC},
            'qz': {'min_level': C.QZ_MIN_LEVEL, 'max_level': C.QZ_MAX_LEVEL},
            's2': {'min_level': C.S2_MIN_LEVEL, 'max_level': C.S2_MAX_LEVEL},
        }
    else:
        raise ValueError(f"unknown kind {kind!r}")
    return {e: all_params[e] for e in engines if e in all_params}


def write_metadata(run_dir, script, shape, engines, latitudes, longitudes,
                   side_km, radius_km=None, kind='latency',
                   warmup_runs=None, measured_runs=None, queries_total=None,
                   csv_filename=None, raw_filename=None,
                   data_rows=344688, data_table='my_mapdata'):
    """Write metadata.json to run_dir capturing every knob that shaped the run.

    Required:
        run_dir, script, shape, engines, latitudes, longitudes, side_km
    Optional but recommended:
        radius_km        (set when shape='circle')
        kind             ('latency' or 'cell_count'; selects engine-param schema)
        csv_filename     (basename, not full path)
        raw_filename     (basename; latency_sweep only)
        warmup_runs, measured_runs, queries_total  (latency_sweep only)
    """
    metadata = {
        "script":          script,
        "timestamp_utc":   time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "shape":           shape,
        "envelope": {
            "side_km":   side_km,
            "radius_km": radius_km,
        },
        "sampling": {
            "latitudes":      list(latitudes),
            "longitudes":     list(longitudes),
            "warmup_runs":    warmup_runs,
            "measured_runs":  measured_runs,
            "queries_total":  queries_total,
        },
        "engines":        list(engines),
        "engine_params":  collect_engine_params(engines, kind),
        "data": {
            "table": data_table,
            "rows":  data_rows,
        },
        "outputs": {
            "csv": csv_filename,
            "raw": raw_filename,
        },
    }
    path = os.path.join(run_dir, "metadata.json")
    with open(path, "w") as f:
        json.dump(metadata, f, indent=2)
    print(f"[metadata] wrote {path}")
    return path
