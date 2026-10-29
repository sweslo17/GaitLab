"""Parsing fixtures verify encoding; they are not benchmark data."""
import struct
import unittest

from prepare_cambridge import parse_acceleration, window_counts


class CambridgeParserTests(unittest.TestCase):
    def test_binary_and_text_preserve_acceleration_and_native_time(self):
        rows = [(1234567890123, 2, 1.0, 2.0, 3.0),
                (1234567890123, 1, 0.5, -1.0, 9.75),
                (1234577890123, 1, 1.0, -2.0, 9.5)]
        binary = b"".join(struct.pack(">qBfff", *row) for row in rows)
        text = "\n".join(" ".join(map(str, row)) for row in rows).encode()
        expected = [(row[0], *row[2:]) for row in rows if row[1] == 1]
        self.assertEqual(parse_acceleration(binary, ".out"), expected)
        self.assertEqual(parse_acceleration(text, ".dat"), expected)

    def test_truncated_and_nonfinite_records_fail(self):
        with self.assertRaises(ValueError):
            parse_acceleration(b"bad", ".out")
        with self.assertRaises(ValueError):
            parse_acceleration(b"1 1 nan 0 9.8", ".dat")

    def test_all_boundary_combinations_detect_cancelling_endpoint_effects(self):
        counts = window_counts([10, 30], {
            "reference_start_us": 20, "reference_end_us": 30,
            "alternative_reference_start_us": 10, "alternative_reference_end_us": 20,
        })
        self.assertEqual(counts["primary/primary"], 1)
        self.assertEqual(counts["alternative/alternative"], 1)
        self.assertEqual(counts["primary/alternative"], 0)
        self.assertEqual(counts["alternative/primary"], 2)


if __name__ == "__main__":
    unittest.main()
