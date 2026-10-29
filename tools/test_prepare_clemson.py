import unittest
from prepare_clemson import reference_steps

class ClemsonReferenceTests(unittest.TestCase):
    def test_counts_only_full_steps_and_reports_shifts(self):
        steps, shifts = reference_steps('12 right\n20 leftshift\n28 left\n')
        self.assertEqual(steps, [12, 28])
        self.assertEqual(shifts, [20])

    def test_unknown_labels_fail(self):
        with self.assertRaises(ValueError):
            reference_steps('12 unknown\n')

    def test_invalid_reference_order_and_indices_fail(self):
        for text in ['-1 left\n', '2 left\n2 right\n', '3 left\n2 right\n']:
            with self.subTest(text=text), self.assertRaises(ValueError):
                reference_steps(text)
