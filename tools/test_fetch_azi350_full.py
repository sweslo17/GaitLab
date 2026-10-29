"""Check source integrity and distinguish summary metadata from sensor trials."""
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from fetch_azi350_full import PREFIX, TREE, git_blob_sha, verify_archive


class FullArchiveTests(unittest.TestCase):
    def fixture(self, root, corrupt=False):
        files = {
            "participant_summary_public.csv": b"participant,trials\nparticipant_001,1\n",
            "participant_001/hand/running/trial_01.csv": b"elapsedMillis,label,actionKeyword\n0,running,running\n",
        }
        archive, tree = root / "source.zip", root / "tree.json"
        with zipfile.ZipFile(archive, "w") as output:
            for name, raw in files.items():
                output.writestr(PREFIX + name, raw + (b"corrupt" if corrupt else b""))
        tree.write_text(json.dumps({"sha": TREE, "truncated": False, "tree": [
            {"path": name, "type": "blob", "size": len(raw), "sha": git_blob_sha(raw)}
            for name, raw in files.items()]}))
        return archive, tree

    def test_summary_is_preserved_but_not_counted_as_sensor_trial(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive, tree = self.fixture(root)
            result = verify_archive(archive, tree, root / "data")
            self.assertEqual(result["csv_count"], 2)
            self.assertEqual(result["trial_count"], 1)
            self.assertEqual(result["trials"][0]["activity"], "running")
            self.assertEqual(result["source_files"][0]["source_path"], "participant_summary_public.csv")

    def test_corrupt_archive_writes_no_dataset(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive, tree = self.fixture(root, corrupt=True)
            with self.assertRaisesRegex(ValueError, "integrity mismatch"):
                verify_archive(archive, tree, root / "data")
            self.assertFalse((root / "data").exists())


if __name__ == "__main__":
    unittest.main()
