"""Check original-data integrity and explicit handling of missing IMU rows."""
import csv
import io
import unittest

from normalize_azi350 import normalize_bytes


HEADER = "elapsedMillis,accelerometerAccelerationX,accelerometerAccelerationY,accelerometerAccelerationZ\n"


class NormalizeTests(unittest.TestCase):
    def test_preserves_relative_time_and_axes_and_records_zero_rows(self):
        text, audit = normalize_bytes((HEADER + "10,0,0,0\n20.125,1.25,-2,9.81\n").encode())
        self.assertEqual(list(csv.DictReader(io.StringIO(text))), [
            {"timestamp_us": "20125", "ax": "1.25", "ay": "-2", "az": "9.81"}])
        self.assertEqual(audit["skipped_zero_acceleration_source_lines"], [2])
        self.assertEqual(audit["source_samples"], 2)

    def test_nonfinite_and_bad_numbers_fail_even_on_zero_rows(self):
        for row in ("1,nan,0,9.8", "nan,0,0,0", "1,bad,0,9.8", "1,0,0"):
            with self.subTest(row=row), self.assertRaises(ValueError):
                normalize_bytes((HEADER + row + "\n").encode())

    def test_nonincreasing_time_and_no_valid_data_fail(self):
        for rows in ("1,0,0,9.8\n1,0,0,9.8\n", "1,0,0,0\n"):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                normalize_bytes((HEADER + rows).encode())


if __name__ == "__main__":
    unittest.main()
