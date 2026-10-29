import unittest
from summarize_benchmarks import summarize

class SummaryTests(unittest.TestCase):
    def test_absolute_error_does_not_cancel_and_uses_scored_window(self):
        rows = [{'replay_status': 'PASS', 'candidate_steps': 99,
                 'candidate_steps_in_reference_window': p,
                 'reference_count': 10, 'count_error': p - 10,
                 'count_error_percent': (p - 10) * 10} for p in [8, 12]]
        r = summarize(rows)
        self.assertEqual(r['signed_total_error_percent'], 0)
        self.assertEqual(r['weighted_absolute_error_percent'], 20)
        self.assertEqual(r['predicted_steps_in_scored_windows'], 20)

    def test_missing_truth_and_failed_replay_are_not_scored(self):
        r = summarize([{'replay_status': 'FAIL'}, {'replay_status': 'PASS',
                      'candidate_steps': 3, 'reference_count': None}])
        self.assertEqual(r['reference_scored_trials'], 0)
        self.assertNotIn('weighted_absolute_error_percent', r)
