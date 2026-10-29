"""Offline checks for WalkRec source conversion and reference selection."""
import unittest
from pathlib import Path
import tempfile
import zipfile

from prepare_walkrec import corrected_count, normalize_acceleration, prepare, reference_scope


class WalkRecTests(unittest.TestCase):
    def test_count_uses_corrected_reference_not_main_detector(self):
        text = "main_ACC:\n 16 steps\nmergedGT (v2):\n6 steps\ncorrected GT:\n6 steps"
        self.assertEqual(corrected_count(text), 6)
        self.assertIsNone(corrected_count("main_ACC:\n 16 steps"))

    def test_native_time_order_and_axes_preserved(self):
        text = ("global_time, local_timestamp, acc_x, acc_y, acc_z, acc_module\n"
                "12:00:00.020, 1020000000, 1, 2, 9.81, 10\n"
                "12:00:00.010, 1010000000, 3, 4, 9.82, 10\n"
                "12:00:00.020, 1020000000, 1, 2, 9.81, 10\n")
        rows, report = normalize_acceleration(text)
        self.assertEqual(rows, [(0, 3.0, 4.0, 9.82), (10000, 1.0, 2.0, 9.81)])
        self.assertEqual(report["identical_duplicate_timestamps_removed"], 1)
        self.assertEqual(report["source_nonincreasing_pairs"], 1)

    def test_conflicting_timestamp_is_rejected(self):
        text = ("local_timestamp,acc_x,acc_y,acc_z\n"
                "1000,1,2,3\n1000,4,5,6\n")
        with self.assertRaisesRegex(ValueError, "Conflicting"):
            normalize_acceleration(text)

    def test_reference_disagreement_withholds_score_and_preserves_record(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "source.zip"
            prefix = "source/DATA/building1/user1/hybrid_tests/record/record"
            with zipfile.ZipFile(archive, "w") as stream:
                stream.writestr(prefix + "@main_ACC.csv",
                                "local_timestamp,acc_x,acc_y,acc_z\n1000,1,2,9.81\n1001000,3,4,9.82\n")
                stream.writestr(prefix + "@NOTES.txt", "corrected GT:\n1 steps")
                stream.writestr(prefix + "@GT.csv", "global_time_peak,acc_peak\n1,2\n2,3\n")
            report = prepare(archive, root / "normalized", root / "manifest.json")
            self.assertEqual(report["source_recordings"], 1)
            self.assertEqual(report["preparation_failures"], [])
            trial = report["trials"][0]
            self.assertIsNone(trial["reference_count"])
            self.assertEqual(trial["reference_notes_count"], 1)
            self.assertEqual(trial["reference_gt_rows"], 2)
            self.assertTrue(trial["gravity_included"])

    def test_scope_rejects_reference_outside_main_recording(self):
        source = ("global_time,local_timestamp,acc_x,acc_y,acc_z\n"
                  "12:00:00.000,0,1,2,9.81\n12:00:00.010,10000000,1,2,9.81\n")
        inside = [{"global_time_peak": "12:00:00.005", "global_time_valley": "12:00:00.008"}]
        outside = [{"global_time_peak": "12:01:00.000", "global_time_valley": "12:01:00.005"}]
        self.assertEqual(reference_scope(source, inside)["status"], "PASS")
        result = reference_scope(source, outside)
        self.assertEqual(result["status"], "FAIL")
        self.assertEqual(result["out_of_scope_peaks"], 1)


if __name__ == "__main__":
    unittest.main()
