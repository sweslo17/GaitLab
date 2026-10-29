"""Export derived Apple waist and Harvard pelvis replay streams.

Original archives stay unchanged. This prepares signal replay only. No complete
step truth or independently verified event alignment is asserted.
"""
from __future__ import annotations

import argparse
from collections import Counter
import csv
import io
import json
import math
from pathlib import Path
import zipfile

from inspect_zenodo import inspect


def export_apple(root: Path, out: Path) -> list[dict]:
    trials = []
    with zipfile.ZipFile(root / "Dataset.zip") as archive:
        names = sorted(n for n in archive.namelist()
                       if not n.startswith("__MACOSX/") and "_Waist_" in n and n.endswith(".csv"))
        for number, name in enumerate(names):
            rows = csv.DictReader(io.StringIO(archive.read(name).decode("utf-8-sig")))
            target = out / f"apple_{number:04d}.csv"
            first = None
            last = None
            nonincreasing = 0
            samples = 0
            with target.open("w", newline="") as stream:
                writer = csv.writer(stream)
                writer.writerow(["timestamp_us", "ax", "ay", "az"])
                for row in rows:
                    timestamp = float(row["timestamp"])
                    if first is None:
                        first = timestamp
                    us = round((timestamp - first) * 1000)
                    values = [(float(row["userAcceleration" + axis]) + float(row["gravity" + axis])) * 9.80665
                              for axis in "XYZ"]
                    if not all(math.isfinite(x) for x in [timestamp, *values]):
                        raise ValueError(f"Nonfinite Apple measurement: {name}")
                    if last is not None and us <= last:
                        nonincreasing += 1
                    last = us
                    writer.writerow([us, *values])
                    samples += 1
            trials.append({
                "id": f"apple_{number:04d}", "dataset": "apple_watch",
                "file": str(target), "source_member": name,
                "participant": name.split("/")[1],
                "activity": Path(name).name.split("_")[0].lower(),
                "gravity_included": True,
                "accuracy_eligible": False,
                "representation": "DERIVED Core Motion (userAcceleration + gravity) * 9.80665, m/s^2; not native raw",
                "timestamp_conversion": "relative to first native timestamp (ms), rounded to microseconds",
                "input_samples": samples, "nonincreasing_timestamps": nonincreasing,
                "ground_truth": "partial plate contact only; no archive alignment manifest; NOT SCORED",
            })
    return trials


def export_harvard(root: Path, out: Path) -> list[dict]:
    trials = []
    with zipfile.ZipFile(root / "running_treadmill_overground_outside.zip") as archive:
        names = sorted(n for n in archive.namelist()
                       if n.startswith(("OG/", "OUT/")) and n.endswith(".csv"))
        for number, name in enumerate(names):
            rows = csv.DictReader(io.StringIO(archive.read(name).decode("utf-8-sig")))
            target = out / f"harvard_{number:04d}.csv"
            timestamp = 0.0
            samples = 0
            means = [0.0] * 3
            with target.open("w", newline="") as stream:
                writer = csv.writer(stream)
                writer.writerow(["timestamp_us", "ax", "ay", "az"])
                for row in rows:
                    dt = float(row["delta_time"])
                    values = [float(row["pel_acc_" + axis]) for axis in "xyz"]
                    if not all(math.isfinite(x) for x in [dt, *values]) or dt <= 0:
                        raise ValueError(f"Invalid Harvard measurement: {name}")
                    writer.writerow([round(timestamp * 1e6), *values])
                    timestamp += dt
                    for i, value in enumerate(values):
                        means[i] += value
                    samples += 1
            mean_norm = math.sqrt(sum((x / samples) ** 2 for x in means)) if samples else 0
            trials.append({
                "id": f"harvard_{number:04d}", "dataset": "harvard",
                "file": str(target), "source_member": name,
                "participant": name.split("/")[1], "activity": "running",
                "gravity_included": True,
                "accuracy_eligible": False,
                "physical_units_independently_verified": False,
                "representation": "source pelvis acceleration, physical-scale m/s^2 assumed from Xsens convention and nonzero gravity mean; no scale fitting",
                "unit_assumption": "archive README omits acceleration units; interpret replay as exploratory only",
                "timestamp_conversion": "cumulative source delta_time seconds, first sample at zero",
                "input_samples": samples, "mean_acceleration_vector_norm": mean_norm,
                "ground_truth": "OG and OUT have no force plate or per-step labels; NOT SCORED",
            })
    return trials


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-dir", type=Path, default=Path("data/public/normalized/zenodo"))
    parser.add_argument("--manifest", type=Path, default=Path("reports/public/zenodo_replay_manifest.json"))
    args = parser.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    roots = [Path("data/public/apple_watch"), Path("data/public/harvard")]
    integrity = [inspect(root) for root in roots]
    trials = export_apple(roots[0], args.out_dir) + export_harvard(roots[1], args.out_dir)
    report = {
        "schema": "gaitlab.normalized-replay-manifest.v1", "trials": trials,
        "archive_integrity": [{"record_id": item["record_id"], "sha256": item["files"][0]["sha256"]} for item in integrity],
        "metadata_conflicts": [
            "Apple Zenodo API describes 757 validated/584 complete; GitHub describes 492/395; archive has 469 waist,490 wrist,810 force CSV files.",
            "Apple Zenodo API says CC0; GitHub and paper say CC-BY-4.0. Retain attribution and do not redistribute this local copy.",
            "Apple archive omits trial_manifest.csv,alignment_log.csv,data_dictionary.csv described by GitHub README.",
        ],
        "excluded_from_replay": "Harvard 9390 TM_FP/OG_FP stride windows stay in original archive; never concatenate them into artificial continuous data",
        "verification_level": "exploratory production-engine signal replay only; no reference accuracy claim",
    }
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(dict(Counter(t["dataset"] for t in trials))))


if __name__ == "__main__":
    main()
