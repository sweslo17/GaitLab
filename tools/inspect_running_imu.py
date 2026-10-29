"""Inspect pinned Running_IMU originals without inferring contact timestamps."""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
from pathlib import Path

import numpy as np
from scipy.io import loadmat


SOURCE = "https://github.com/MyriamLubrano/Running_IMU"
REVISION = "9eb366966caf008d62ecc3675b11fd1c48978ec2"
EXPECTED = {
    "data_IMU.mat": "694a39cb698e81d1134c4729b70dafd9165c34aa",
    "data_OJ.mat": "493cd90a0be0122c8723f64d8615833b2c156b1d",
}


def describe(value):
    """Record structure and ranges, without emitting the source measurements."""
    if isinstance(value, dict):
        return {key: describe(item) for key, item in value.items()
                if not key.startswith("__")}
    if isinstance(value, (list, tuple)):
        return [describe(item) for item in value]
    if isinstance(value, np.ndarray):
        if value.dtype == object:
            return {"shape": list(value.shape), "items": [describe(item)
                    for item in value.ravel()]}
        result = {"shape": list(value.shape), "dtype": str(value.dtype)}
        if np.issubdtype(value.dtype, np.number):
            finite = np.isfinite(value)
            result["finite_count"] = int(finite.sum())
            if finite.any():
                result.update(minimum=float(value[finite].min()),
                              maximum=float(value[finite].max()))
        return result
    if isinstance(value, np.generic):
        return value.item()
    return value


def inspect(directory: Path) -> dict:
    report = {
        "schema": "gaitlab.running-imu-inventory.v1",
        "source": SOURCE,
        "revision": REVISION,
        "sampling_hz_from_source_main": 800,
        "acceleration_unit_from_source_main": "m/s^2",
        "angular_velocity_unit_from_source_main": "rad/s",
        "files": {},
    }
    for filename, expected in EXPECTED.items():
        path = directory / filename
        raw = path.read_bytes()
        blob = hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest()
        if blob != expected:
            raise ValueError(f"Original integrity mismatch: {path}")
        report["files"][filename] = {
            "file": str(path), "bytes": len(raw), "git_blob_sha1": blob,
            "sha256": hashlib.sha256(raw).hexdigest(),
            "integrity": "PASS", "structure": describe(loadmat(path, simplify_cells=True)),
        }
    return report


def export_lower_back(directory: Path) -> dict:
    """Export a replay view, retaining originals and documenting reconstructed time."""
    data = loadmat(directory / "data_IMU.mat", simplify_cells=True)["data_IMU"]
    reference = loadmat(directory / "data_OJ.mat", simplify_cells=True)["data_OJ"]
    destination = directory / "normalized"
    destination.mkdir(parents=True, exist_ok=True)
    trials = []
    reference_summary = {}
    for speed, arrays in data["lower_back"]["acceleration"].items():
        values = []
        for item in reference[speed]:
            for side in ("R", "L"):
                values.extend(np.atleast_1d(item["stride_" + side]).tolist())
        reference_summary[speed] = {
            "reference_trials": len(reference[speed]),
            "stride_duration_count": len(values),
            "median_stride_duration_s": float(np.median(values)),
            "source_fields": ["stance_R", "stride_R", "stance_L", "stride_L"],
            "has_contact_timestamps": False,
            "has_full_window_step_count": False,
        }
        for index, acceleration in enumerate(arrays, start=1):
            acceleration = np.asarray(acceleration)
            if acceleration.ndim != 2 or acceleration.shape[1] != 3:
                raise ValueError(f"Unexpected lower-back shape: {speed}/{index}")
            if not np.isfinite(acceleration).all():
                raise ValueError(f"Non-finite lower-back acceleration: {speed}/{index}")
            path = destination / f"lower_back_{speed}_{index:03d}.csv"
            with path.open("w", newline="", encoding="utf-8") as stream:
                writer = csv.writer(stream)
                writer.writerow(["timestamp_us", "ax", "ay", "az"])
                for sample, row in enumerate(acceleration):
                    writer.writerow([sample * 1250, *row])
            trials.append({
                "file": str(path), "dataset": "Running_IMU", "subject": None,
                "subject_note": "No subject identifiers in released MAT hierarchy",
                "condition": speed, "placement": "lower_back", "rows": len(acceleration),
                "duration_s": (len(acceleration) - 1) / 800,
                "sampling_hz": 800, "timestamp_source": "Reconstructed sample index / 800 Hz",
                "acceleration_unit": "m/s^2",
                "gravity_included": True,
                "gravity_declaration_basis": "Replay assumption: source acceleration in m/s^2 and per-trial mean-vector norm near 9.81; no gravity removal applied by this adapter",
                "mean_acceleration_vector_norm": float(np.linalg.norm(acceleration.mean(axis=0))),
                "gravity_compatibility": "Mean vector near 9.81 supports gravity presence; not independently calibrated",
                "reference_availability": "Stride and stance durations only; no event timestamps or full-window count",
                "reference_pairing": "Positional trial index is not independently documented; no per-trial score",
            })
    return {"schema": "gaitlab.running-imu-replay-inputs.v1", "source": SOURCE,
            "revision": REVISION, "trials": trials, "reference_summary": reference_summary,
            "verification_level": "Signal replay only; no synchronized per-event reference",
            "warning": "Short 1.3–3.4 s clips include engine warmup; do not infer full-recording count accuracy"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", type=Path, default=Path("data/public/running_imu"))
    parser.add_argument("--out", type=Path,
                        default=Path("reports/public/running_imu_inventory.json"))
    parser.add_argument("--export", action="store_true", help="Export lower-back replay CSV files")
    args = parser.parse_args()
    report = inspect(args.dir)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if args.export:
        manifest = export_lower_back(args.dir)
        manifest_path = args.out.with_name("running_imu_replay_inputs.json")
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"report": str(args.out), "integrity": "PASS"}))


if __name__ == "__main__":
    main()
