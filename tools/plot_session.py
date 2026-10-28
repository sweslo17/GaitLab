#!/usr/bin/env python3
"""Visual QA of GaitLab recording. Run with: uv run --with matplotlib tools/plot_session.py SESSION_DIR"""
import argparse
import csv
from pathlib import Path
import matplotlib.pyplot as plt

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('session', type=Path)
parser.add_argument('--seconds', type=float, default=12., help='Window length to plot')
parser.add_argument('--offset', type=float, default=0., help='Seconds after first sample')
parser.add_argument('--save', type=Path, help='Save PNG instead of opening window')
args = parser.parse_args()

with (args.session/'accelerometer.csv').open(newline='', encoding='utf-8') as f:
    samples = list(csv.DictReader(f))
with (args.session/'steps.csv').open(newline='', encoding='utf-8') as f:
    events = list(csv.DictReader(f))
if not samples:
    parser.error('Empty acceleration data')
t0 = int(samples[0]['event_timestamp_us'])
selected = [r for r in samples if args.offset <= (int(r['event_timestamp_us'])-t0)/1e6 <= args.offset+args.seconds]
if not selected:
    parser.error('No samples in selected time window')
times = [(int(r['event_timestamp_us'])-t0)/1e6 for r in selected]
plt.figure(figsize=(12,5))
plt.plot(times, [float(r['vertical_m_s2']) for r in selected], label='gravity-axis dynamic acceleration', linewidth=1.1, alpha=.6)
plt.plot(times, [float(r['filtered_m_s2']) for r in selected], label='filtered', linewidth=1.5)
plt.plot(times, [float(r['peak_threshold_m_s2']) for r in selected], label='adaptive threshold', linestyle='--')
start, end = times[0], times[-1]
first = True
for row in events:
    sec = (int(row['event_timestamp_us'])-t0)/1e6
    if start <= sec <= end:
        plt.axvline(sec, linewidth=.7, alpha=.45, label='candidate step' if first else None)
        first = False
plt.xlabel('time since session first sensor sample (s)')
plt.ylabel('projected acceleration (m/s²)')
plt.title('GaitLab v0.3 • Unvalidated candidate step events')
plt.grid(alpha=.2)
plt.legend(loc='upper right')
plt.tight_layout()
if args.save:
    plt.savefig(args.save, dpi=150)
    print(f'Saved: {args.save}')
else:
    plt.show()
