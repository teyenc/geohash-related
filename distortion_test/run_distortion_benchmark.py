#!/usr/bin/env python3
"""
Geohash vs S2 Range Scan Generation Test (Testing X and Y Distortion)

This script measures how many index range scan cells Geohash and S2 generate
for the same physical search area at different (longitude, latitude) positions
on Earth, for both square (bounding box) and circle (exact polygon) shapes.

It uses PostGIS as the "ground truth" to compute exact bounding boxes for
physical km radii (since lat/lon degrees != km depending on latitude).

Robustness:
  - Pre-flight checks every dependency (psql, ysqlsh, PG running on :54321,
    YB running on :5433, postgis ext, c_geohash ext, yb_geospatial_s2 ext).
  - Auto-creates the databases (test_postgis, test_geo) and extensions if
    missing.
  - Prints a clear PASS/FAIL line per check before running the benchmark.
"""

import subprocess
import sys
import shutil

# -------- Configuration --------
PG_PSQL    = "/usr/pgsql-15/bin/psql"
PG_HOST    = "127.0.0.1"
PG_PORT    = 54321
PG_USER    = "te-yenchou"
PG_DB      = "test_postgis"

YB_YSQL    = "/net/dev-server-te-yenchou/share/code/yugabyte-db/build/latest/postgres/bin/ysqlsh"
YB_HOST    = "127.0.0.1"
YB_PORT    = 5433
YB_USER    = "yugabyte"
YB_DB      = "test_geo"

LATITUDES  = [0, 45, 75, 89.5]
LONGITUDES = [0, 90, 179]
SIZES_KM   = [10, 50]
GEOHASH_PRECISION = 6
S2_LEVEL          = 15
# Realistic production max_cells. 10000 was way too generous and caused
# st_s2covering to spend minutes subdividing along curvy circle edges,
# which piled up queries on the YB tserver and OOM'd the host.
S2_MAX_CELLS      = 100

# Per-query timeouts. The Python timeout only kills the client, so we
# also set a server-side statement_timeout via PG/YB GUC so the actual
# query stops on the database too. Use a smaller server-side timeout so
# the DB always wins the race against the client.
QUERY_TIMEOUT_SEC        = 30
SERVER_STATEMENT_TIMEOUT = "20s"

# Hard-stop guard: if we see this many consecutive timeouts, abort the
# benchmark to avoid stacking up hung queries on the server.
MAX_CONSECUTIVE_TIMEOUTS = 3

# ST_Buffer(geography, ...)::geometry produces a polygon with many
# vertices by default (~32 segments per quarter circle). Capping
# quad_segs keeps the polygon small so st_s2covering doesn't have to
# trace a wiggly curve.  See PostGIS docs:
# https://postgis.net/docs/ST_Buffer.html (parameter `quad_segs`).
BUFFER_QUAD_SEGS = 8


# -------- Pretty printing --------
def info(msg):  print(f"\033[36m[info]\033[0m {msg}")
def ok(msg):    print(f"\033[32m[ ok ]\033[0m {msg}")
def warn(msg):  print(f"\033[33m[warn]\033[0m {msg}")
def fail(msg):  print(f"\033[31m[fail]\033[0m {msg}")


# -------- Query helpers --------
import os

def _run(cmd, env=None):
    """Run a subprocess. Returns (rc, stdout+stderr)."""
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.STDOUT,
                                      timeout=QUERY_TIMEOUT_SEC, env=env)
        return 0, out.decode("utf-8").strip()
    except subprocess.CalledProcessError as e:
        return e.returncode, (e.output or b"").decode("utf-8").strip()
    except subprocess.TimeoutExpired:
        return -1, "timeout"
    except FileNotFoundError as e:
        return -2, str(e)


def _env_with_timeout(with_timeout):
    """Set statement_timeout server-side via libpq's PGOPTIONS env var.
    Cleaner than `SET statement_timeout = ...; ...` because that prints
    `SET` as an extra output line which corrupts the parsed values."""
    if not with_timeout:
        return None
    env = os.environ.copy()
    env["PGOPTIONS"] = f"-c statement_timeout={SERVER_STATEMENT_TIMEOUT}"
    return env


def run_pg(query, db=PG_DB, with_timeout=True):
    return _run([PG_PSQL, "-h", PG_HOST, "-p", str(PG_PORT),
                 "-U", PG_USER, "-d", db, "-t", "-A", "-c", query],
                env=_env_with_timeout(with_timeout))


def run_yb(query, db=YB_DB, with_timeout=True):
    return _run([YB_YSQL, "-h", YB_HOST, "-p", str(YB_PORT),
                 "-U", YB_USER, "-d", db, "-t", "-A", "-c", query],
                env=_env_with_timeout(with_timeout))


# -------- Pre-flight checks --------
def preflight():
    info("Running pre-flight checks...")
    all_ok = True

    if not shutil.which(PG_PSQL):
        fail(f"psql binary not found at {PG_PSQL}"); return False
    ok(f"found psql at {PG_PSQL}")

    if not shutil.which(YB_YSQL):
        fail(f"ysqlsh binary not found at {YB_YSQL}"); return False
    ok(f"found ysqlsh at {YB_YSQL}")

    rc, out = run_pg("SELECT 1", db="postgres")
    if rc != 0:
        fail(f"PostGIS server unreachable on {PG_HOST}:{PG_PORT}\n      {out}")
        fail("Hint: start it with `bash /net/dev-server-te-yenchou/share/code/geohash-related/s2_vs_geohash_benchmark/setup/00_setup_postgis.sh`")
        all_ok = False
    else:
        ok(f"PostgreSQL alive on {PG_HOST}:{PG_PORT}")

    rc, out = run_yb("SELECT 1", db="yugabyte")
    if rc != 0:
        fail(f"YugabyteDB server unreachable on {YB_HOST}:{YB_PORT}\n      {out}")
        fail(f"Hint: start it with `{YB_YSQL.replace('build/latest/postgres/bin/ysqlsh', 'bin/yugabyted')} start --base_dir=/tmp/yugabyted-bench --advertise_address=127.0.0.1`")
        all_ok = False
    else:
        ok(f"YugabyteDB alive on {YB_HOST}:{YB_PORT}")

    if not all_ok:
        return False

    rc, _ = run_pg(f"SELECT 1 FROM pg_database WHERE datname='{PG_DB}'", db="postgres")
    rc2, out = run_pg(f"SELECT 1 FROM pg_database WHERE datname='{PG_DB}'", db="postgres")
    if rc2 == 0 and out.strip() == "":
        info(f"creating database {PG_DB}")
        run_pg(f"CREATE DATABASE {PG_DB}", db="postgres")
    rc, out = run_pg("SELECT 1 FROM pg_extension WHERE extname='postgis'")
    if rc != 0 or out.strip() == "":
        info("creating postgis extension")
        rc, out = run_pg("CREATE EXTENSION IF NOT EXISTS postgis")
        if rc != 0:
            fail(f"could not install postgis: {out}"); return False
    ok(f"PG database {PG_DB} has postgis")

    rc, out = run_yb(f"SELECT 1 FROM pg_database WHERE datname='{YB_DB}'", db="yugabyte")
    if rc == 0 and out.strip() == "":
        info(f"creating database {YB_DB}")
        run_yb(f"CREATE DATABASE {YB_DB}", db="yugabyte")
    for ext in ("c_geohash", "yb_geospatial_s2"):
        rc, out = run_yb(f"SELECT 1 FROM pg_extension WHERE extname='{ext}'")
        if rc != 0 or out.strip() == "":
            info(f"creating extension {ext}")
            rc, out = run_yb(f"CREATE EXTENSION IF NOT EXISTS {ext} CASCADE")
            if rc != 0:
                fail(f"could not install {ext}: {out}"); return False
    ok(f"YB database {YB_DB} has c_geohash + yb_geospatial_s2")

    rc, _ = run_pg("SELECT ST_AsText(ST_MakePoint(0,0))")
    if rc != 0: fail("PostGIS smoke test failed"); return False
    rc, _ = run_yb("SELECT array_length(c_geohash_covering(0,0,1,1,5),1)")
    if rc != 0: fail("c_geohash smoke test failed"); return False
    rc, _ = run_yb("SELECT array_length(st_s2covering(ST_MakeEnvelope(0,0,1,1,4326), 15, 100),1)")
    if rc != 0: fail("st_s2covering smoke test failed"); return False
    ok("smoke tests passed for postgis, c_geohash, st_s2covering")

    return True


# -------- Benchmark --------
def _normalize_result(rc, raw):
    """Convert a (rc, raw_output) pair into a short cell label for the table."""
    if rc == -1:
        return "timeout"
    if rc != 0:
        return "ERROR"
    val = raw.strip()
    return val if val else "ERROR"


def benchmark():
    consecutive_timeouts = 0

    print()
    print(f"# Geohash vs S2 Range Scan Generation Test (Testing X and Y Distortion)")
    print(f"**Geohash Precision:** {GEOHASH_PRECISION} | "
          f"**S2 Level:** {S2_LEVEL} (Max Cells: {S2_MAX_CELLS}) | "
          f"**Buffer quad_segs:** {BUFFER_QUAD_SEGS} | "
          f"**Server timeout:** {SERVER_STATEMENT_TIMEOUT}\n")

    print("| Search Radius | Longitude (X) | Latitude (Y) | Shape | "
          "Geohash Range Scans | S2 Range Scans |")
    print("|---|---|---|---|---|---|")

    for size in SIZES_KM:
        radius_m = size * 1000
        for lon in LONGITUDES:
            for lat in LATITUDES:
                bbox_q = (
                    f"SELECT ST_XMin(g)||'|'||ST_YMin(g)||'|'||ST_XMax(g)||'|'||ST_YMax(g) "
                    f"FROM (SELECT ST_Buffer(ST_MakePoint({lon},{lat})::geography,{radius_m},"
                    f"'quad_segs={BUFFER_QUAD_SEGS}')::geometry AS g) t"
                )
                rc, bbox = run_pg(bbox_q)
                if rc != 0 or bbox.count("|") < 3:
                    print(f"| {size}km | {lon}° | {lat}° | bbox-failed | - | - |")
                    continue

                # Last line of psql output is the data row; ignore the
                # SET statement_timeout NOTICE line if it appears first.
                bbox_line = [ln for ln in bbox.splitlines() if ln.count("|") == 3][-1]
                xmin, ymin, xmax, ymax = [v.strip() for v in bbox_line.split("|")]

                rc_gh, raw_gh = run_yb(
                    f"SELECT array_length(c_geohash_covering({xmin},{ymin},{xmax},{ymax},{GEOHASH_PRECISION}),1)"
                )
                rc_sq, raw_sq = run_yb(
                    f"SELECT array_length(st_s2covering(ST_MakeEnvelope({xmin},{ymin},{xmax},{ymax},4326),{S2_LEVEL},{S2_MAX_CELLS}),1)"
                )
                # NOTE: yb_geospatial_s2 only defines ST_Buffer(geometry, double, integer)
                # (yb_geospatial_s2--1.0.sql line 139), not the PostGIS-style
                # text-arg form ('quad_segs=N'). Pass the integer directly.
                rc_ci, raw_ci = run_yb(
                    f"SELECT array_length(st_s2covering("
                    f"ST_Buffer(ST_MakePoint({lon},{lat})::geography,{radius_m},"
                    f"{BUFFER_QUAD_SEGS})::geometry,"
                    f"{S2_LEVEL},{S2_MAX_CELLS}),1)"
                )

                gh      = _normalize_result(rc_gh, raw_gh)
                s2_sq   = _normalize_result(rc_sq, raw_sq)
                s2_circ = _normalize_result(rc_ci, raw_ci)

                if -1 in (rc_gh, rc_sq, rc_ci):
                    consecutive_timeouts += 1
                else:
                    consecutive_timeouts = 0

                print(f"| {size}km | {lon}° | {lat}° | Square (BBox)  | {gh} | {s2_sq} |")
                print(f"| {size}km | {lon}° | {lat}° | Circle (Exact) | {gh}* | {s2_circ} |")

                if consecutive_timeouts >= MAX_CONSECUTIVE_TIMEOUTS:
                    print()
                    fail(f"Aborting: {MAX_CONSECUTIVE_TIMEOUTS} consecutive timeouts. "
                         "Lower S2_MAX_CELLS / BUFFER_QUAD_SEGS or shrink SIZES_KM.")
                    return

    print()
    print(r"*\*Geohash has no native circle-covering function, so it must scan the entire bounding box.*")
    print(r"*If Geohash returns ERROR at Longitude 179°, it is because the bounding box crosses 180° (antimeridian), which causes an integer underflow crash in `c_geohash.c`.*")


def main():
    if not preflight():
        fail("Pre-flight failed; aborting benchmark.")
        sys.exit(1)
    benchmark()


if __name__ == "__main__":
    main()
