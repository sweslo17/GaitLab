#!/usr/bin/env python3
"""Download and verify the pinned AZI350 repository without changing its data."""
from __future__ import annotations

import argparse
import collections
import csv
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
from urllib.request import urlopen
import zipfile

REPOSITORY = "AZI350/Smartphone-IMU-Three-Positions-Dataset"
COMMIT = "348768b8034ccd7d01d696cd62cc1d673a34a186"
TREE = "be9fe07958cc9d974fb94ae7d2ba8a6225afc9d3"
ARCHIVE_URL = f"https://codeload.github.com/{REPOSITORY}/zip/{COMMIT}"
TREE_URL = f"https://api.github.com/repos/{REPOSITORY}/git/trees/{TREE}?recursive=1"
PREFIX = f"Smartphone-IMU-Three-Positions-Dataset-{COMMIT}/"


def git_blob_sha(raw: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(raw)).encode("ascii") + b"\0" + raw).hexdigest()


def verify_archive(archive_path: Path, tree_path: Path, destination: Path) -> dict:
    tree = json.loads(tree_path.read_text(encoding="utf-8"))
    if tree.get("sha") != TREE or tree.get("truncated") is not False:
        raise ValueError("The source tree is incomplete or has the wrong revision")
    expected = {item["path"]: item for item in tree["tree"] if item["type"] == "blob"}
    trials = []
    source_files = []
    activity_counts: collections.Counter = collections.Counter()
    with zipfile.ZipFile(archive_path) as archive:
        names = [name for name in archive.namelist() if not name.endswith("/")]
        if any(not name.startswith(PREFIX) for name in names):
            raise ValueError("Unexpected archive root")
        actual = {name[len(PREFIX):] for name in names}
        if actual != set(expected) or len(names) != len(actual):
            raise ValueError("Archive files differ from the pinned source tree")
        # Validate all paths and bytes before writing any data to the destination.
        for path, spec in expected.items():
            parts = PurePosixPath(path).parts
            if not parts or ".." in parts or PurePosixPath(path).is_absolute():
                raise ValueError("Unsafe source path")
            raw = archive.read(PREFIX + path)
            if len(raw) != spec["size"] or git_blob_sha(raw) != spec["sha"]:
                raise ValueError(f"Source integrity mismatch: {path}")
        for path, spec in expected.items():
            raw = archive.read(PREFIX + path)
            local = destination / path
            local.parent.mkdir(parents=True, exist_ok=True)
            local.write_bytes(raw)
            item = {"source_path": path, "file": str(local), "bytes": len(raw),
                    "git_blob_sha1": spec["sha"],
                    "sha256": hashlib.sha256(raw).hexdigest()}
            if path.endswith(".csv") and len(PurePosixPath(path).parts) >= 4:
                rows = csv.DictReader(io.StringIO(raw.decode("utf-8-sig")))
                item["columns"] = rows.fieldnames
                labels: collections.Counter = collections.Counter()
                actions: collections.Counter = collections.Counter()
                count = 0
                for row in rows:
                    count += 1
                    labels[row.get("label", "")] += 1
                    actions[row.get("actionKeyword", "")] += 1
                parts = PurePosixPath(path).parts
                item.update({"participant": parts[0], "placement": parts[1],
                             "activity": parts[2], "rows": count,
                             "row_labels": dict(labels), "action_keywords": dict(actions)})
                activity_counts[parts[2]] += 1
                trials.append(item)
            else:
                source_files.append(item)
    return {
        "schema": "gaitlab.azi350-full-manifest.v1",
        "repository": f"https://github.com/{REPOSITORY}",
        "commit": COMMIT, "tree": TREE, "archive_url": ARCHIVE_URL,
        "tree_url": TREE_URL,
        "archive_sha256": hashlib.sha256(archive_path.read_bytes()).hexdigest(),
        "verification": "PASS: all archive files match pinned Git blob SHA-1 and size",
        "license": "CC BY-NC-ND 4.0; preserve originals; no data redistribution",
        "ground_truth": "activity labels only; no reference step count or event times",
        "csv_count": sum(path.endswith(".csv") for path in expected),
        "trial_count": len(trials), "activity_trial_counts": dict(activity_counts),
        "notes": [
            "README states 696 CSV files, but the pinned repository contains 647 CSV files.",
            "README does not specify sensor units. Acceleration units require explicit review before replay.",
            "Original initialization rows and all samples are preserved without filtering.",
        ],
        "source_files": source_files, "trials": trials,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--tree", type=Path)
    parser.add_argument("--dir", type=Path, default=Path("data/public/azi350_full"))
    parser.add_argument("--out", type=Path, default=Path("reports/public/azi350_full_manifest.json"))
    args = parser.parse_args()
    args.dir.mkdir(parents=True, exist_ok=True)
    archive = args.archive or args.dir / "source_archive.zip"
    tree = args.tree or args.dir / "source_tree.json"
    for path, source, supplied in ((archive, ARCHIVE_URL, args.archive),
                                    (tree, TREE_URL, args.tree)):
        if supplied is None:
            with urlopen(source, timeout=300) as response:
                path.write_bytes(response.read())
    result = verify_archive(archive, tree, args.dir)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: result[key] for key in
                      ("commit", "verification", "csv_count", "trial_count", "activity_trial_counts", "notes")}, indent=2))


if __name__ == "__main__":
    main()
