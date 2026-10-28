import csv
import tempfile
import unittest
from pathlib import Path
from score_events import compare_events, force_contacts, read_event_times


class ScoringTests(unittest.TestCase):
    def test_perfect_match(self):
        m=compare_events([100000,500000,900000], [100000,500000,900000], 30)
        self.assertEqual(m['f1'],1)
        self.assertEqual(m['timing_mae_ms'],0)

    def test_one_to_one_matching_prevents_double_count(self):
        m=compare_events([100000,120000], [110000], 30)
        self.assertEqual((m['matched'],m['false_positive'],m['false_negative']),(1,1,0))

    def test_offset_alignment(self):
        m=compare_events([1000000],[1500000], 50, offset_ms=500)
        self.assertEqual(m['f1'],1)

    def test_precision_recall(self):
        m=compare_events([100000,700000], [100000,500000], 50)
        self.assertEqual(m['precision'],.5)
        self.assertEqual(m['recall'],.5)
        self.assertEqual(m['f1'],.5)

    def test_empty_is_not_perfect_score(self):
        m=compare_events([],[],50)
        self.assertIsNone(m['f1'])

    def test_bad_tolerance_and_duplicates(self):
        with self.assertRaises(ValueError): compare_events([1],[1],-1)
        with self.assertRaises(ValueError): compare_events([1,1],[1],50)

    def test_force_plate_threshold_and_duration(self):
        with tempfile.TemporaryDirectory() as td:
            p=Path(td)/'force.csv'
            with p.open('w',newline='') as f:
                writer=csv.writer(f)
                writer.writerow(['timestamp','Force_Z'])
                for i in range(151):
                    t=i/1000
                    force=140 if 0.010<=t<0.110 else 0
                    writer.writerow([f'{t:.3f}',force])
            events=force_contacts(p)
            self.assertEqual(events, [10000])

    def test_short_force_spike_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            p=Path(td)/'force.csv'
            with p.open('w',newline='') as f:
                writer=csv.writer(f);writer.writerow(['timestamp','Force_Z'])
                for i in range(151):
                    t=i/1000
                    writer.writerow([f'{t:.3f}', 200 if 0.010<=t<0.035 else 0])
            self.assertEqual(force_contacts(p), [])

    def test_csv_reader_requires_monotonic_timestamps(self):
        with tempfile.TemporaryDirectory() as td:
            p=Path(td)/'events.csv'
            p.write_text('t\n1\n1\n')
            with self.assertRaises(ValueError): read_event_times(p,'t','s')


if __name__=='__main__':
    unittest.main()
