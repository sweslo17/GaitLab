"""Round-trip and deliberate corruption tests of GaitLab's export validator."""
import csv
import json
import tempfile
import unittest
from pathlib import Path
from analyze_session import analyze


def make_session(folder, hz=100, n=100, gap_index=None, gap_us=0):
    us = round(1e6 / hz)
    times = [i * us + (gap_us if gap_index is not None and i >= gap_index else 0)
             for i in range(n)]
    with (folder / 'accelerometer.csv').open('w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['event_timestamp_us', 'ax_m_s2', 'ay_m_s2', 'az_m_s2',
                    'vertical_m_s2', 'filtered_m_s2', 'peak_threshold_m_s2', 'accepted'])
        for t in times:
            w.writerow([t, 0, 0, 9.81, 0, 0, 1, 1])
    event_times = times[::35]
    with (folder / 'steps.csv').open('w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['event_timestamp_us', 'interval_ms', 'estimated_cadence_spm'])
        for i, t in enumerate(event_times):
            w.writerow([t, f'{(t-event_times[i-1])/1000:.2f}' if i else '', ''])
    with (folder / 'quality.csv').open('w', newline='') as f:
        f.write('event_timestamp_us,actual_hz\n')
    with (folder / 'gyroscope.csv').open('w', newline='') as f:
        f.write('event_timestamp_us,gx_rad_s,gy_rad_s,gz_rad_s\n')
    (folder / 'metadata.json').write_text(json.dumps({'schema':'gaitlab.session.v3'}))
    (folder / 'summary.json').write_text(json.dumps({
        'candidate_steps':len(event_times), 'accepted_accel_samples':n,
        'rejected_accel_samples':0,
    }))
    return event_times


class ReportTests(unittest.TestCase):
    def test_valid_session_reference_comparison_and_gap(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            events = make_session(p, gap_index=50, gap_us=100000, n=300)
            report = analyze(p, ref_steps=len(events), ref_spm=60000/350)
            self.assertTrue(report['integrity_ok'], report['integrity_errors'])
            self.assertEqual(report['candidate_steps'], len(events))
            self.assertEqual(report['step_count_absolute_error'], 0)
            self.assertTrue(report['cadence_within_3_spm'])
            self.assertEqual(report['large_sampling_gaps'], 1)
            self.assertGreater(report['estimated_missing_acceleration_samples'], 0)
            window = analyze(p, start_seconds=0, duration_seconds=.5)
            self.assertLess(window['accelerometer_samples_in_window'], report['accelerometer_rows_entire_session'])
            self.assertEqual(window['candidate_steps'], 2)

    def test_legitimate_50hz_samples_are_not_counted_as_dropouts(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            make_session(p, hz=50, n=250)
            report = analyze(p)
            self.assertTrue(report['integrity_ok'])
            self.assertEqual(report['median_sampling_hz'], 50)
            self.assertEqual(report['large_sampling_gaps'], 0)

    def test_mismatched_summary_is_reported(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            make_session(p)
            summary_file = p / 'summary.json'
            summary = json.loads(summary_file.read_text())
            summary['candidate_steps'] += 1
            summary_file.write_text(json.dumps(summary))
            report = analyze(p)
            self.assertFalse(report['integrity_ok'])
            self.assertTrue(any('summary candidate_steps' in e for e in report['integrity_errors']))

    def test_orphan_step_timestamp_is_reported(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            make_session(p)
            steps_file = p / 'steps.csv'
            content = steps_file.read_text().replace('350000,350.00', '350001,350.00')
            steps_file.write_text(content)
            report = analyze(p)
            self.assertFalse(report['integrity_ok'])
            self.assertTrue(any('not found among accepted accel' in e for e in report['integrity_errors']))

    def test_empty_session_does_not_crash(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            make_session(p, n=0)
            report = analyze(p)
            self.assertTrue(report['integrity_ok'])
            self.assertEqual(report['candidate_steps'], 0)
            self.assertIsNone(report['median_sampling_hz'])


if __name__ == '__main__':
    unittest.main()
