#!/usr/bin/env python3
"""Prepare audited AZI350 replay inputs while preserving downloaded originals."""
from __future__ import annotations

import argparse
import csv
from decimal import Decimal, InvalidOperation
import hashlib
import io
import json
import math
from pathlib import Path

from fetch_azi350_full import git_blob_sha


def normalize_bytes(raw: bytes) -> tuple[str, dict]:
    reader = csv.DictReader(io.StringIO(raw.decode("utf-8-sig")))
    axes = ["accelerometerAcceleration" + axis for axis in "XYZ"]
    if not set(["elapsedMillis", *axes]).issubset(reader.fieldnames or []):
        raise ValueError("Missing required raw acceleration or timestamp columns")
    output = io.StringIO()
    writer = csv.writer(output, lineterminator="\n")
    writer.writerow(["timestamp_us", "ax", "ay", "az"])
    last_time = None
    source_count = 0
    written = 0
    skipped = []
    for line, row in enumerate(reader, 2):
        source_count += 1
        try:
            if None in row or any(value is None for value in row.values()):
                raise ValueError("Wrong field count")
            time = Decimal(row["elapsedMillis"]) * 1000
            xyz = [float(row[axis]) for axis in axes]
            if not time.is_finite() or not all(math.isfinite(x) for x in xyz):
                raise ValueError("Non-finite input")
            if time != time.to_integral_value() or time < 0:
                raise ValueError("Timestamp must represent nonnegative integer microseconds")
            timestamp = int(time)
            if last_time is not None and timestamp <= last_time:
                raise ValueError("Non-increasing source timestamp")
            last_time = timestamp
        except (ValueError, TypeError, InvalidOperation) as error:
            raise ValueError(f"Malformed source line {line}: {error}") from error
        if all(value == 0 for value in xyz):
            skipped.append(line)
            continue
        writer.writerow([timestamp, *[row[axis] for axis in axes]])
        written += 1
    if not written:
        raise ValueError("No nonzero gravity-inclusive samples")
    return output.getvalue(), {
        "source_samples": source_count, "output_samples": written,
        "skipped_zero_acceleration_rows": len(skipped),
        "skipped_zero_acceleration_source_lines": skipped,
        "zero_row_policy": "Exclude all-zero raw acceleration as missing IMU placeholders; this is an explicit preprocessing assumption, not an activity annotation",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-manifest", type=Path, default=Path("reports/public/azi350_full_manifest.json"))
    parser.add_argument("--dir", type=Path, default=Path("data/public/azi350_normalized"))
    parser.add_argument("--out", type=Path, default=Path("reports/public/azi350_replay_inputs.json"))
    args = parser.parse_args()
    source = json.loads(args.source_manifest.read_text())
    trials = []
    for trial in source["trials"]:
        raw = Path(trial["file"]).read_bytes()
        if git_blob_sha(raw) != trial["git_blob_sha1"]:
            raise ValueError(f"Original source changed: {trial['file']}")
        normalized, audit = normalize_bytes(raw)
        output = args.dir / trial["source_path"]
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(normalized, encoding="utf-8")
        trials.append({
            "file": str(output), "source_file": trial["file"],
            "source_git_blob_sha1": trial["git_blob_sha1"],
            "normalized_sha256": hashlib.sha256(normalized.encode()).hexdigest(),
            "participant": trial["participant"], "placement": trial["placement"],
            "activity": trial["activity"], "gravity_included": True,
            "acceleration_units": "m/s^2 (explicit assumption; README does not specify units)",
            "acceleration_columns": "accelerometerAccelerationX/Y/Z; gravity included assumption",
            "timestamp_conversion": "elapsedMillis * 1000; original relative origin retained",
            "reference_count": None, "ground_truth": "activity only", **audit,
        })
    report = {"schema": "gaitlab.azi350-replay-inputs.v1", "commit": source["commit"],
              "source_manifest": str(args.source_manifest), "trials": trials}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"Prepared {len(trials)} trials; skipped zero acceleration rows: "
          f"{sum(trial['skipped_zero_acceleration_rows'] for trial in trials)}")


if __name__ == "__main__":
    main()
