"""Prepare original Cambridge smartphone streams and walking reference windows.

The official parser identifies acceleration as sensor 1 and timestamps as ns.
The source does not state annotation index origin, so export both 0- and 1-based
window interpretations. Replay the whole trace before scoring either window.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import tarfile

SOURCE = "https://api.repository.cam.ac.uk/server/api/core/bitstreams/e0f7852d-16ea-4bfa-8805-d8e111aef593/content"
MD5 = "e745f874cf15e15e5a3c0141b296647c"


def window_counts(events: list[int], trial: dict) -> dict:
    return {f"{start_name}/{end_name}": sum(start <= event <= end for event in events)
            for start_name, start in [("primary", trial["reference_start_us"]),
                                      ("alternative", trial["alternative_reference_start_us"])]
            for end_name, end in [("primary", trial["reference_end_us"]),
                                  ("alternative", trial["alternative_reference_end_us"])]}


def apply_window_sensitivity(replay: Path) -> None:
    manifest_path = Path("reports/public/cambridge_replay_inputs.json")
    manifest = json.loads(manifest_path.read_text())
    reports = {trial["file"]: trial for trial in json.loads(replay.read_text())["trials"]}
    ambiguous = []
    scored = 0
    for trial in manifest["trials"]:
        if not trial["reference_window_valid"] or trial["reference_count_in_original"] is None:
            continue
        report = reports[trial["file"]]
        if report["source_trace_sha256"] != trial["source_trace_sha256"] or report["replay_status"] != "PASS":
            raise ValueError(f"Unusable replay for sensitivity: {trial['file']}")
        counts = window_counts(report["candidate_step_times_us"], trial)
        trial["candidate_counts_by_boundary_convention"] = counts
        if len(set(counts.values())) > 1:
            trial["reference_count"] = None
            trial["reference_comparison_withheld"] = "Candidate count changes with undocumented annotation boundary convention"
            ambiguous.append({"file": trial["file"], "counts": counts})
        else:
            trial["reference_count"] = trial["reference_count_in_original"]
            trial.pop("reference_comparison_withheld", None)
            scored += 1
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    summary = {"conventions_checked": 4, "reference_eligible": scored,
               "boundary_ambiguous": len(ambiguous), "ambiguous_trials": ambiguous,
               "warning": "Stable count under boundary shifts does not independently prove the source index convention"}
    Path("reports/public/cambridge_window_sensitivity.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary))


def parse_acceleration(raw: bytes, suffix: str) -> list[tuple[int, float, float, float]]:
    if suffix == ".out":
        if len(raw) % 21:
            raise ValueError("Truncated 21-byte source record")
        records = struct.iter_unpack(">qBfff", raw)
    elif suffix == ".dat":
        records = []
        for line in raw.decode().splitlines():
            if not line.strip():
                continue
            fields = line.split()
            if len(fields) != 5:
                raise ValueError("Malformed source record")
            records.append((int(fields[0]), int(fields[1]), *map(float, fields[2:])))
    else:
        raise ValueError("Unknown source encoding")
    result = []
    for timestamp, sensor, x, y, z in records:
        if sensor not in {1, 2, 3} or not all(math.isfinite(v) for v in [x, y, z]):
            raise ValueError("Invalid source sensor or measurement")
        if sensor == 1:
            result.append((timestamp, x, y, z))
    if not result:
        raise ValueError("No source acceleration")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-windows", type=Path,
                        help="Apply four-boundary-convention sensitivity to an existing production replay")
    args = parser.parse_args()
    if args.check_windows:
        apply_window_sensitivity(args.check_windows)
        return
    root = Path("data/public/cambridge")
    source = root / "ubicomp13.tar.gz"
    raw = source.read_bytes()
    if hashlib.md5(raw, usedforsecurity=False).hexdigest() != MD5:
        raise ValueError("Official source MD5 mismatch")
    with tarfile.open(source) as archive:
        counts = {}
        for line in archive.extractfile("ubicomp13/groundtruth_SC.txt").read().decode().splitlines():
            if line.strip():
                key, count = line.split()
                if key in counts or int(count) < 0:
                    raise ValueError("Invalid reference count")
                counts[key] = int(count)
        windows = {}
        for line in archive.extractfile("ubicomp13/groundtruth_WD.txt").read().decode().splitlines():
            match = re.fullmatch(r"(p\d+\.\d+\S+)\s+\((\d+)\s+(\d+)\)", line.strip())
            if match:
                key, start, end = match.groups()
                if key in windows:
                    raise ValueError("Duplicate reference window")
                windows[key] = (int(start), int(end))
        for filename in ["README.txt", "parseTraces.py"]:
            (root / filename).write_bytes(archive.extractfile("ubicomp13/" + filename).read())
    destination = root / "normalized"
    destination.mkdir(parents=True, exist_ok=True)
    trials = []
    with tarfile.open(source) as archive:
        for member in archive:
            if not member.isfile() or Path(member.name).suffix not in {".out", ".dat"}:
                continue
            raw_trace = archive.extractfile(member).read()
            samples = parse_acceleration(raw_trace, Path(member.name).suffix)
            experiment, _, _, _, placement = Path(member.name).stem.split("_", 4)
            key = experiment + placement
            window = windows.get(key)
            window_valid = window is not None and 1 <= window[0] <= window[1] < len(samples)
            start, end = window if window_valid else (None, None)
            first = samples[0][0]
            timestamps = [round((row[0] - first) / 1000) for row in samples]
            target = destination / (Path(member.name).stem + ".csv")
            with target.open("w", newline="") as stream:
                writer = csv.writer(stream)
                writer.writerow(["timestamp_us", "ax", "ay", "az"])
                for timestamp, (_, x, y, z) in zip(timestamps, samples):
                    writer.writerow([timestamp, x, y, z])
            trials.append({
                "file": str(target), "dataset": "Cambridge", "participant": experiment.split(".")[0],
                "experiment": experiment, "placement": placement, "activity": "walking",
                "source_member": member.name, "source_trace_sha256": hashlib.sha256(raw_trace).hexdigest(),
                "gravity_included": True,
                "acceleration_representation": "Android TYPE_ACCELEROMETER sensor 1, m/s^2 including gravity; original axes unchanged",
                "timestamp_source": "source sensor-native ns minus first acceleration timestamp, rounded to us",
                "input_samples": len(samples),
                "nonincreasing_timestamps": sum(b <= a for a, b in zip(timestamps, timestamps[1:])),
                "reference_count": counts.get(experiment) if window_valid else None,
                "reference_count_in_original": counts.get(experiment),
                "reference_window_valid": window_valid,
                "reference_window_issue": None if window_valid else "Missing or out-of-range source walking window; count withheld",
                "reference_start_us": timestamps[start] if window_valid else None,
                "reference_end_us": timestamps[end] if window_valid else None,
                "alternative_reference_start_us": timestamps[start - 1] if window_valid else None,
                "alternative_reference_end_us": timestamps[end - 1] if window_valid else None,
                "reference_index_start": start, "reference_index_end": end,
                "reference_index_origin": "NOT SPECIFIED in original README/parser; zero-based primary, one-based sensitivity",
                "reference_endpoint_convention": "NOT SPECIFIED; primary inclusive endpoints, check all primary/alternative boundary combinations",
                "reference_source": "groundtruth_SC.txt per experiment and groundtruth_WD.txt per recording",
                "reference_note": "Missing experiment count remains null; evaluate all primary/alternative start/end combinations and withhold if count changes",
            })
    report = {
        "schema": "gaitlab.cambridge-replay-inputs.v1", "source": SOURCE,
        "official_md5": MD5, "source_sha256": hashlib.sha256(raw).hexdigest(),
        "source_bytes": len(raw), "integrity": "PASS official source MD5",
        "license": "GPL-3.0 according to institutional record; originals not redistributed",
        "trials": trials,
        "warning": "Index-origin ambiguity requires sensitivity analysis before reference-count results are accepted",
    }
    out = Path("reports/public/cambridge_replay_inputs.json")
    out.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"trials": len(trials), "with_count": sum(t["reference_count"] is not None for t in trials),
                      "nonincreasing_timestamps": sum(t["nonincreasing_timestamps"] for t in trials)}))


if __name__ == "__main__":
    main()
