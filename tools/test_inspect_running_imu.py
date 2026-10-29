"""Offline tests for Running_IMU conversion and provenance checks."""
import csv
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import numpy as np

from inspect_running_imu import export_lower_back, inspect


class RunningImuTests(unittest.TestCase):
    def test_modified_original_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "data_IMU.mat").write_bytes(b"not the research data")
            with self.assertRaisesRegex(ValueError, "integrity mismatch"):
                inspect(directory)

    def test_export_preserves_axes_units_and_marks_reference_limits(self):
        acceleration = np.array([[1.0, 2.0, 9.81], [3.0, 4.0, 9.82]])
        imu = {"data_IMU": {"lower_back": {"acceleration": {"v15": [acceleration]}}}}
        oj = {"data_OJ": {"v15": [{"stride_R": np.array([0.6, 0.62]),
                                    "stride_L": 0.61}]}}
        with tempfile.TemporaryDirectory() as temporary, patch(
            "inspect_running_imu.loadmat", side_effect=[imu, oj]
        ):
            manifest = export_lower_back(Path(temporary))
            trial = manifest["trials"][0]
            with Path(trial["file"]).open(newline="") as stream:
                rows = list(csv.DictReader(stream))
            self.assertEqual([row["timestamp_us"] for row in rows], ["0", "1250"])
            self.assertEqual(float(rows[1]["az"]), 9.82)
            self.assertTrue(trial["gravity_included"])
            self.assertIn("assumption", trial["gravity_declaration_basis"])
            self.assertIsNone(trial["subject"])
            self.assertFalse(manifest["reference_summary"]["v15"]["has_contact_timestamps"])
            self.assertFalse(manifest["reference_summary"]["v15"]["has_full_window_step_count"])


if __name__ == "__main__":
    unittest.main()
