"""Prepare pinned WalkRec source recordings for offline production replay."""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import math
from pathlib import Path
import re
import statistics
import zipfile


REVISION = "2878087e552c48ee867bb5bf78c2998929496f96"
SOURCE = "https://gitlab.citius.gal/fernando.estevez/walking-recognition-dataset"


def time_of_day_ms(value: str) -> int:
    hours, minutes, seconds = value.strip().split(":")
    return int(hours) * 3600000 + int(minutes) * 60000 + round(float(seconds) * 1000)


def reference_scope(text: str, gt_rows: list[dict]) -> dict:
    """Require reference events within the main phone recording clock bounds."""
    rows = list(csv.DictReader(io.StringIO(text), skipinitialspace=True))
    if not rows or "global_time" not in rows[0]:
        return {"status": "UNVERIFIED", "reason": "Main global clock unavailable"}
    times = [time_of_day_ms(row["global_time"]) for row in rows]
    midnight = max(times) - min(times) > 43200000
    def unwrap(t):
        return t + 86400000 if midnight and t < 43200000 else t
    times = [unwrap(t) for t in times]
    lo, hi = min(times), max(times)
    native = sorted({int(row["local_timestamp"]) for row in rows})
    tolerance = statistics.median(b-a for a, b in zip(native, native[1:])) / 1e6 + 1
    peaks = [unwrap(time_of_day_ms(row["global_time_peak"])) for row in gt_rows]
    valleys = [unwrap(time_of_day_ms(row["global_time_valley"])) for row in gt_rows]
    outside = [t for t in peaks if t < lo-tolerance or t > hi+tolerance]
    outside_valleys = [t for t in valleys if t < lo-tolerance or t > hi+tolerance]
    return {"status": "FAIL" if outside or outside_valleys else "PASS",
            "method": "Main source global_time bounds vs combined GT global_time_peak/valley; no alignment inferred",
            "main_global_start_ms": lo, "main_global_end_ms": hi,
            "edge_tolerance_ms": tolerance, "out_of_scope_peaks": len(outside),
            "out_of_scope_valleys": len(outside_valleys),
            "maximum_peak_distance_outside_ms": max((max(lo-t, t-hi) for t in outside), default=0)}


def corrected_count(notes: str) -> int | None:
    matches = re.findall(r"corrected\s+GT:\s*(\d+)\s+steps", notes, re.I)
    if len(matches) > 1:
        raise ValueError("Multiple corrected reference counts")
    return int(matches[0]) if matches else None


def normalize_acceleration(text: str) -> tuple[list, dict]:
    reader = csv.DictReader(io.StringIO(text), skipinitialspace=True)
    rows = []
    for row in reader:
        t = int(row["local_timestamp"])
        xyz = tuple(float(row["acc_" + axis]) for axis in "xyz")
        if t < 0 or not all(math.isfinite(v) for v in xyz):
            raise ValueError("Invalid acceleration sample")
        rows.append((t, *xyz))
    nonmonotonic = sum(b[0] <= a[0] for a, b in zip(rows, rows[1:]))
    original_rows = len(rows)
    by_time = {}
    for row in rows:
        if row[0] in by_time and by_time[row[0]] != row:
            raise ValueError("Conflicting acceleration at duplicate native timestamp")
        by_time[row[0]] = row
    rows = sorted(by_time.values())
    if len(rows) < 2:
        raise ValueError("Not enough acceleration samples")
    first = rows[0][0]
    output = [((r[0] - first) // 1000, *r[1:]) for r in rows]
    if any(b[0] <= a[0] for a, b in zip(output, output[1:])):
        raise ValueError("Microsecond conversion collapses distinct timestamps")
    return output, {"source_rows": original_rows, "normalized_rows": len(output),
                    "source_nonincreasing_pairs": nonmonotonic,
                    "identical_duplicate_timestamps_removed": original_rows - len(rows),
                    "timestamp_source": "Source local_timestamp nanoseconds, sorted, relative to first sample, floored to microseconds",
                    "timestamp_unit_basis": "Android sensor native timestamp convention; ns intervals agree with recording wall duration"}


def prepare(archive: Path, destination: Path, out: Path) -> dict:
    with archive.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    destination.mkdir(parents=True, exist_ok=True)
    report = {"schema": "gaitlab.walkrec-inputs.v1", "source": SOURCE,
              "revision": REVISION, "license": "CC BY 4.0", "archive": str(archive),
              "archive_url": f"https://gitlab.citius.gal/api/v4/projects/1369/repository/archive.zip?sha={REVISION}",
              "archive_sha256": digest, "archive_hash_basis": "Locally measured after pinned HTTPS download; no publisher archive checksum available",
              "trials": [], "preparation_failures": []}
    with zipfile.ZipFile(archive) as source:
        bad = source.testzip()
        if bad:
            raise ValueError(f"Archive CRC mismatch: {bad}")
        report["archive_crc_status"] = "PASS"
        report["archive_files"] = len(source.infolist())
        paths = sorted(p for p in source.namelist() if p.endswith("@main_ACC.csv"))
        for index, path in enumerate(paths):
            try:
                raw = source.read(path)
                samples, details = normalize_acceleration(raw.decode("utf-8-sig"))
                prefix = path.removesuffix("@main_ACC.csv")
                notes_path = prefix + "@NOTES.txt"
                gt_path = prefix + "@GT.csv"
                notes = source.read(notes_path).decode("utf-8-sig")
                notes_count = corrected_count(notes)
                gt_rows = list(csv.DictReader(io.StringIO(source.read(gt_path).decode("utf-8-sig"))))
                gt_count = len(gt_rows)
                compatible = notes_count is None or notes_count == gt_count
                scope = reference_scope(raw.decode("utf-8-sig"), gt_rows)
                eligible = compatible and scope["status"] == "PASS"
                output = destination / f"trial_{index:04d}.csv"
                with output.open("w", newline="", encoding="utf-8") as stream:
                    writer = csv.writer(stream)
                    writer.writerow(["timestamp_us", "ax", "ay", "az"])
                    writer.writerows(samples)
                parts = path.split("/")
                data_index = parts.index("DATA")
                building, subject, location = parts[data_index + 1:data_index + 4]
                trial = {"file": str(output), "dataset": "WalkRec", "source_file": path,
                         "source_sha256": hashlib.sha256(raw).hexdigest(),
                         "subject": building + "/" + subject, "placement": location,
                         "condition": "walking and nonwalking natural activity", "gravity_included": True,
                         "acceleration_unit": "m/s^2", "gravity_declaration_basis": "Source README explicitly states gravity-inclusive raw acceleration",
                         "reference_type": "Combined leg-phone peak-valley detections, source corrected GT where supplied; not universally manual video truth",
                         "reference_scope": "Full recording, same record ID; engine startup warmup retained",
                         "reference_notes_count": notes_count, "reference_gt_rows": gt_count,
                         "reference_crosscheck": "PASS" if compatible else "FAIL: corrected count differs from GT rows",
                         "reference_scope_check": scope, "accuracy_eligible": eligible,
                         "reference_count": (notes_count if notes_count is not None else gt_count) if eligible else None,
                         **details}
                report["trials"].append(trial)
            except (ValueError, KeyError, UnicodeError) as error:
                report["preparation_failures"].append({"source_file": path, "error": str(error)})
        report["source_recordings"] = len(paths)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, default=Path("data/public/walkrec/source.zip"))
    parser.add_argument("--destination", type=Path, default=Path("data/public/walkrec/normalized"))
    parser.add_argument("--out", type=Path, default=Path("reports/public/walkrec_inputs.json"))
    args = parser.parse_args()
    report = prepare(args.archive, args.destination, args.out)
    print(json.dumps({"recordings": report["source_recordings"], "normalized": len(report["trials"]),
                      "failures": len(report["preparation_failures"]), "archive_crc": report["archive_crc_status"]}))
    return 1 if report["preparation_failures"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
