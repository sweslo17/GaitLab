"""Unit fixtures check adapter math only; they are not public-data evidence."""
import csv
from pathlib import Path
import tempfile
import unittest
import zipfile

from prepare_zenodo_replay import export_apple, export_harvard


class ReplayAdapterTests(unittest.TestCase):
    def test_apple_reconstructs_gravity_and_preserves_duplicate_times(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = ("timestamp,userAccelerationX,userAccelerationY,userAccelerationZ,gravityX,gravityY,gravityZ\n"
                      "1000,0.1,0,0,-1,0,0\n1000,0.2,0,0,-1,0,0\n1010,0.3,0,0,-1,0,0\n")
            with zipfile.ZipFile(root / "Dataset.zip", "w") as archive:
                archive.writestr("Dataset/P1/Running_Waist_Trial_1.csv", source)
            trials = export_apple(root, root)
            self.assertEqual(trials[0]["nonincreasing_timestamps"], 1)
            with Path(trials[0]["file"]).open() as stream:
                rows = list(csv.DictReader(stream))
            self.assertEqual([int(row["timestamp_us"]) for row in rows], [0, 0, 10000])
            self.assertAlmostEqual(float(rows[0]["ax"]), -0.9 * 9.80665)

    def test_harvard_resets_time_per_file_and_excludes_stride_windows(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = "delta_time,pel_acc_x,pel_acc_y,pel_acc_z\n0.01,9.8,0,0\n0.01,10,0,0\n"
            with zipfile.ZipFile(root / "running_treadmill_overground_outside.zip", "w") as archive:
                for name in ["OG/P1/a.csv", "OUT/P2/b.csv", "TM_FP/P1/stride.csv"]:
                    archive.writestr(name, source)
            trials = export_harvard(root, root)
            self.assertEqual(len(trials), 2)
            for trial in trials:
                with Path(trial["file"]).open() as stream:
                    rows = list(csv.DictReader(stream))
                self.assertEqual([int(row["timestamp_us"]) for row in rows], [0, 10000])


if __name__ == "__main__":
    unittest.main()
