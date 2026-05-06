#!/usr/bin/env python3
"""
One-time organizer: migrates the legacy flat layout under results/ into
the per-run subfolder layout.

  Before:                                After:
    results/                               results/
      radius_sweep_<ts>.csv                  run_<ts>/
      radius_sweep_<ts>_latency.png            radius_sweep.csv
      radius_sweep_<ts>_cells.png              latency.png
      radius_sweep_<ts>_latency.md             cells.png
      radius_sweep_<ts>_cells.md               latency.md
                                               cells.md

Idempotent: safe to re-run. Only moves files; never deletes.
Skips files already in run_<ts>/ subdirs.
"""

import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
RESULTS = os.path.join(HERE, "results")

LEGACY_RE = re.compile(
    r"^radius_sweep_(\d{8}_\d{6})(?:_(latency|cells))?\.(csv|png|md)$"
)


def main():
    if not os.path.isdir(RESULTS):
        sys.exit(f"No results directory at {RESULTS}")

    moves = []
    for fn in os.listdir(RESULTS):
        full = os.path.join(RESULTS, fn)
        if not os.path.isfile(full):
            continue
        m = LEGACY_RE.match(fn)
        if not m:
            continue
        ts, kind, ext = m.groups()
        run_dir = os.path.join(RESULTS, f"run_{ts}")
        if kind is None:
            # legacy: radius_sweep_<ts>.csv  →  run_<ts>/radius_sweep.csv
            new_name = f"radius_sweep.{ext}"
        else:
            # legacy: radius_sweep_<ts>_latency.png  →  run_<ts>/latency.png
            new_name = f"{kind}.{ext}"
        moves.append((full, run_dir, new_name))

    if not moves:
        print("Nothing to organize — already in new layout.")
        return

    print(f"{len(moves)} files to move:\n")
    for src, dst_dir, dst_name in moves:
        print(f"  {os.path.basename(src):<60} → {os.path.basename(dst_dir)}/{dst_name}")
    print()

    for src, dst_dir, dst_name in moves:
        os.makedirs(dst_dir, exist_ok=True)
        dst = os.path.join(dst_dir, dst_name)
        if os.path.exists(dst):
            print(f"  ! {dst} already exists, skipping {src}")
            continue
        shutil.move(src, dst)
    print("\nDone.")


if __name__ == "__main__":
    main()
