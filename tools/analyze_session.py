#!/usr/bin/env python3
"""GaitLab v0.3 CSV QA / independent reference comparison. Python 3.11+.

No third-party packages, works with `uv run tools/analyze_session.py ...`.
This is an engineering QA report, NOT a clinical gait assessment.
"""
import argparse
import csv
import json
import math
import statistics
from pathlib import Path


def read_rows(path):
    with path.open(newline='', encoding='utf-8') as stream:
        yield from csv.DictReader(stream)


def analyze(folder, ref_steps=None, ref_spm=None, start_seconds=0.0, duration_seconds=None):
    timestamps = []
    all_accepted_timestamps = []
    count = 0
    raw_rejected = 0
    peaks = []
    integrity_errors = []
    prior_step_ts = None
    prior_accel_ts = None
    prev_step_for_interval = None
    for row in read_rows(folder / 'accelerometer.csv'):
        count += 1
        if row.get('accepted') == '0':
            raw_rejected += 1
            continue
        t = int(row['event_timestamp_us'])
        if prior_accel_ts is not None and t <= prior_accel_ts:
            integrity_errors.append(f'non-increasing accepted accel timestamp at row {count}')
        prior_accel_ts = t
        for key in ('ax_m_s2', 'ay_m_s2', 'az_m_s2', 'filtered_m_s2'):
            if not math.isfinite(float(row[key])):
                integrity_errors.append(f'non-finite accepted {key} at row {count}')
                break
        timestamps.append(t)
    all_accepted_timestamps = timestamps
    accel_set = set(timestamps)
    for index, row in enumerate(read_rows(folder / 'steps.csv'), 1):
        t = int(row['event_timestamp_us'])
        if prior_step_ts is not None and t <= prior_step_ts:
            integrity_errors.append(f'non-increasing step timestamp at row {index}')
        if t not in accel_set:
            integrity_errors.append(f'candidate step {index} not found among accepted accel timestamps')
        interval_str = row['interval_ms']
        if interval_str:
            interval = float(interval_str)
            if prev_step_for_interval is None or abs(interval - (t - prev_step_for_interval) / 1000) > .06:
                integrity_errors.append(f'step interval inconsistent with timestamps at row {index}')
        prev_step_for_interval = t
        prior_step_ts = t
        peaks.append(t)
    for name in ('metadata.json', 'quality.csv', 'gyroscope.csv', 'summary.json'):
        if not (folder / name).is_file():
            integrity_errors.append(f'missing exported file: {name}')
    summary_file = folder / 'summary.json'
    if summary_file.is_file():
        summary = json.loads(summary_file.read_text(encoding='utf-8'))
        if summary.get('candidate_steps') != len(peaks):
            integrity_errors.append('summary candidate_steps does not match steps.csv')
        if summary.get('accepted_accel_samples') != len(all_accepted_timestamps):
            integrity_errors.append('summary accepted_accel_samples does not match accelerometer.csv')
        if summary.get('rejected_accel_samples') != raw_rejected:
            integrity_errors.append('summary rejected_accel_samples does not match accelerometer.csv')
    metadata_file = folder / 'metadata.json'
    if metadata_file.is_file():
        metadata = json.loads(metadata_file.read_text(encoding='utf-8'))
        if metadata.get('schema') not in ('gaitlab.session.v2', 'gaitlab.session.v3'):
            integrity_errors.append('unknown metadata schema')
    if timestamps:
        window_start = timestamps[0] + int(start_seconds * 1e6)
        window_end = window_start + int(duration_seconds * 1e6) if duration_seconds is not None else None
        timestamps = [t for t in timestamps if t >= window_start and (window_end is None or t < window_end)]
        peaks = [t for t in peaks if t >= window_start and (window_end is None or t < window_end)]
    positive_dt = [(b - a)/1000 for a,b in zip(timestamps,timestamps[1:]) if b > a]
    median_dt = statistics.median(positive_dt) if positive_dt else None
    hz = 1000/median_dt if median_dt else None
    large_gaps = [v for v in positive_dt if median_dt and v > 1.8 * median_dt]
    estimated_missing = sum(max(0, round(v/median_dt)-1) for v in large_gaps) if median_dt else 0
    duration_s = (timestamps[-1]-timestamps[0])/1e6 if len(timestamps)>1 else None
    intervals_ms = [(b-a)/1000 for a,b in zip(peaks,peaks[1:]) if 270 <= (b-a)/1000 <= 900]
    med_step_ms = statistics.median(intervals_ms) if intervals_ms else None
    cadence = 60000/med_step_ms if med_step_ms else None
    cv = (statistics.pstdev(intervals_ms)/statistics.mean(intervals_ms)*100) if len(intervals_ms)>=6 else None
    report = {
        'schema':'gaitlab.qa.v3',
        'integrity_ok': len(integrity_errors) == 0,
        'integrity_errors': integrity_errors[:30],
        'integrity_error_count': len(integrity_errors),
        'window_start_s':start_seconds,
        'window_duration_s':duration_seconds,
        'candidate_steps':len(peaks),
        'accelerometer_rows_entire_session':count,
        'accelerometer_samples_in_window':len(timestamps),
        'accelerometer_rejected_entire_session':raw_rejected,
        'duration_s':round(duration_s,2) if duration_s is not None else None,
        'median_sampling_interval_ms':round(median_dt,3) if median_dt else None,
        'median_sampling_hz':round(hz,2) if hz else None,
        'large_sampling_gaps':len(large_gaps),
        'estimated_missing_acceleration_samples':estimated_missing,
        'estimated_loss_pct':round(100*estimated_missing/(len(timestamps)+estimated_missing),2) if timestamps or estimated_missing else None,
        'median_candidate_step_interval_ms':round(med_step_ms,2) if med_step_ms else None,
        'median_candidate_cadence_spm':round(cadence,2) if cadence else None,
        'candidate_step_time_cv_pct':round(cv,2) if cv is not None else None,
        'interpretation':'Candidate peaks are NOT verified foot contacts; median time difference is only a proxy.'
    }
    if ref_steps is not None:
        abs_error = abs(ref_steps-len(peaks))
        report['reference_steps'] = ref_steps
        report['step_count_absolute_error'] = abs_error
        report['step_count_error_pct'] = round(100*abs_error/ref_steps,2) if ref_steps>0 else None
        report['step_count_within_2pct'] = (100*abs_error/ref_steps <= 2) if ref_steps>0 else None
    if ref_spm is not None:
        report['reference_cadence_spm'] = ref_spm
        report['cadence_absolute_error_spm'] = round(abs(cadence-ref_spm),2) if cadence else None
        report['cadence_within_3_spm'] = abs(cadence-ref_spm)<=3 if cadence else None
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('session',type=Path,help='GaitLab session folder containing CSVs')
    parser.add_argument('--reference-steps',type=int,help='Manually counted ground-truth steps')
    parser.add_argument('--reference-spm',type=float,help='Reference cadence (e.g. manual steps / duration)')
    parser.add_argument('--start-seconds',type=float,default=0.,help='Window start relative to first acceleration sample')
    parser.add_argument('--duration-seconds',type=float,help='Length of reference counting window')
    parser.add_argument('--out',type=Path,help='Optional output JSON (default stdout only)')
    args=parser.parse_args()
    for required in ('accelerometer.csv','steps.csv'):
        if not (args.session/required).is_file():
            parser.error(f'Missing {required} in {args.session}')
    if args.reference_steps is not None and args.reference_steps<0:
        parser.error('--reference-steps must be >= 0')
    if args.reference_spm is not None and (not math.isfinite(args.reference_spm) or args.reference_spm < 0):
        parser.error('--reference-spm must be finite and >= 0')
    if args.start_seconds < 0 or not math.isfinite(args.start_seconds):
        parser.error('--start-seconds must be finite and >= 0')
    if args.duration_seconds is not None and (args.duration_seconds<=0 or not math.isfinite(args.duration_seconds)):
        parser.error('--duration-seconds must be finite and > 0')
    report=analyze(args.session,args.reference_steps,args.reference_spm,args.start_seconds,args.duration_seconds)
    content=json.dumps(report,indent=2,ensure_ascii=False)
    print(content)
    if args.out:
        args.out.write_text(content+'\n',encoding='utf-8')

if __name__=='__main__':
    main()
