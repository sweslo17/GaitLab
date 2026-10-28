#!/usr/bin/env python3
"""Fetch *unmodified* public research trial files with pinned Git blob hashes.

Source: https://github.com/AZI350/Smartphone-IMU-Three-Positions-Dataset
License: CC BY-NC-ND 4.0. No downloaded data is bundled or redistributed.
Activity labels are NOT per-step footstrike ground truth.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from urllib.request import urlopen

OWNER_REPO = "AZI350/Smartphone-IMU-Three-Positions-Dataset"
BASE = "https://raw.githubusercontent.com/" + OWNER_REPO + "/main/"
TRIALS = {
    "running_pants": {
        "path": "participant_001/pants_pocket/running/trial_01.csv",
        "blob": "b49521196d25f4d04fc8dd4453d68c56c6008af3",
        "activity": "running", "placement": "pants_pocket",
    },
    "sitting_pants": {
        "path": "participant_001/pants_pocket/sitting/trial_01.csv",
        "blob": "8d38be3ed81e774d8393d28634c04e1983479a4f",
        "activity": "sitting", "placement": "pants_pocket",
    },
    "running_upper": {
        "path": "participant_001/upper_pocket/running/trial_01.csv",
        "blob": "9616625045aeb4f7221861d6e8e3ada6234bffa1",
        "activity": "running", "placement": "upper_pocket",
    },
}


def git_blob_sha(raw: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(raw)).encode("ascii") + b"\0" + raw).hexdigest()


def verify_bytes(raw: bytes, expected_sha: str) -> None:
    actual = git_blob_sha(raw)
    if actual != expected_sha:
        raise ValueError(f"Dataset changed, expected Git blob {expected_sha}, got {actual}")


def acquire(dest: Path, *, fetch: bool) -> list[dict]:
    output = []
    for key, spec in TRIALS.items():
        local = dest / f"{key}.csv"
        if fetch:
            # No transparent data substitutions. Failed download => failed run.
            with urlopen(BASE + spec["path"], timeout=40) as stream:
                raw = stream.read(5_000_000)
            verify_bytes(raw, spec["blob"])
            dest.mkdir(parents=True, exist_ok=True)
            local.write_bytes(raw)
        elif not local.exists():
            raise FileNotFoundError(f"Missing {local}. Download with --fetch")
        raw = local.read_bytes()
        verify_bytes(raw, spec["blob"])
        output.append({"id": key, "file": str(local), "sha": spec["blob"],
                       "rows": raw.count(b"\n") - 1, "activity": spec["activity"],
                       "placement": spec["placement"]})
    return output


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--dir", type=Path, default=Path("data/public/azi350"))
    p.add_argument("--fetch", action="store_true", help="Download pinned source files; network required")
    p.add_argument("--out", type=Path, help="Write dataset manifest JSON")
    args = p.parse_args()
    manifest = {"schema": "gaitlab.public-dataset.v1", "source": BASE,
                "license": "CC BY-NC-ND 4.0; research only, do not redistribute modified originals",
                "ground_truth": "activity only; no annotated individual steps",
                "trials": acquire(args.dir, fetch=args.fetch)}
    result = json.dumps(manifest, indent=2)
    print(result)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(result + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
