"""Check downloaded Zenodo archives against source metadata and inspect schemas.

This is data-integrity evidence, not a step-accuracy benchmark. Originals stay
inside ignored data/public and are never modified or redistributed.
"""
from __future__ import annotations

import argparse
from collections import Counter
import csv
import hashlib
import io
import json
from pathlib import Path
import zipfile


def inspect(root: Path) -> dict:
    record = json.loads((root / "record.json").read_text())
    result = {
        "record_id": record["id"],
        "doi": record["doi"],
        "source": record["links"]["self"],
        "source_license": record["metadata"].get("license"),
        "files": [],
        "verification_level": "download integrity and schema only",
        "step_accuracy": "NOT RUN",
    }
    for spec in record["files"]:
        path = root / spec["key"]
        sha256 = hashlib.sha256()
        md5 = hashlib.md5(usedforsecurity=False)
        with path.open("rb") as stream:
            while block := stream.read(1024 * 1024):
                sha256.update(block)
                md5.update(block)
        if path.stat().st_size != spec["size"]:
            raise ValueError(f"Incomplete source archive: {path}")
        actual = "md5:" + md5.hexdigest()
        if actual != spec["checksum"]:
            raise ValueError(f"Source checksum mismatch: {path}")
        with zipfile.ZipFile(path) as archive:
            bad = archive.testzip()
            if bad is not None:
                raise ValueError(f"Archive CRC failure: {bad}")
            members = [item for item in archive.infolist() if not item.is_dir()]
            scientific_csv = [item.filename for item in members
                              if item.filename.endswith(".csv") and not item.filename.startswith("__MACOSX/")]
            extensions = Counter(Path(item.filename).suffix.lower() for item in members)
            examples = {}
            for item in members:
                suffix = Path(item.filename).suffix.lower()
                if item.filename.startswith("__MACOSX/") or suffix in examples or suffix not in {".csv", ".txt", ".json", ".md", ".mat"}:
                    continue
                example = {"path": item.filename, "bytes": item.file_size}
                if suffix == ".mat":
                    example["header"] = archive.read(item)[:128].decode("ascii", errors="replace")
                else:
                    with archive.open(item) as stream:
                        preview = stream.read(4096).decode("utf-8-sig", errors="replace")
                    example["preview"] = preview
                    if suffix == ".csv":
                        example["columns"] = next(csv.reader(io.StringIO(preview)))
                examples[suffix] = example
            result["files"].append({
                "file": str(path), "bytes": path.stat().st_size,
                "source_checksum": actual, "sha256": sha256.hexdigest(),
                "checksum_status": "PASS", "zip_crc_status": "PASS",
                "archive_file_count": len(members),
                "scientific_csv_count_excluding_resource_forks": len(scientific_csv),
                "csv_top_level_counts": dict(Counter(name.split("/")[0] for name in scientific_csv)),
                "extension_counts": dict(extensions), "schema_examples": examples,
                "paths": [item.filename for item in members],
            })
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--roots", nargs="+", type=Path,
                        default=[Path("data/public/apple_watch"), Path("data/public/harvard")])
    parser.add_argument("--out", type=Path, default=Path("reports/public/zenodo_inventory.json"))
    args = parser.parse_args()
    report = {"schema": "gaitlab.zenodo-inventory.v1", "datasets": [inspect(root) for root in args.roots]}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n")
    for dataset in report["datasets"]:
        for item in dataset["files"]:
            print(dataset["record_id"], item["checksum_status"], item["archive_file_count"], item["extension_counts"])


if __name__ == "__main__":
    main()
