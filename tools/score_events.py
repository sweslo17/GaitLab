#!/usr/bin/env python3
"""Score IMU candidate contacts against independently annotated contact times.

Input CSV time columns must share an aligned time base, or provide offset-ms.
This script never guesses cross-sensor alignment. Default tolerance: 50 ms.
For force plate raw traces, use --reference-force to derive stance onset
from a 50 N threshold and 80 ms minimum duration (research heuristics).
"""
import argparse
import csv
import json
import math
from pathlib import Path


def read_event_times(path, time_field, unit='us'):
    factor = {'us': 1., 'ms': 1e3, 's': 1e6}[unit]
    with Path(path).open(newline='', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        if time_field not in (reader.fieldnames or []):
            raise ValueError(f'Missing time column {time_field!r} in {path}')
        values = [round(float(r[time_field])*factor) for r in reader if r.get(time_field)]
    if any(v < 0 for v in values) or any(b <= a for a,b in zip(values,values[1:])):
        raise ValueError('Event times must be nonnegative and strictly increasing')
    return values


def force_contacts(path, time_field='timestamp', force_field='Force_Z',
                   time_unit='s', threshold_n=50., min_contact_ms=80.,
                   min_separation_ms=250.):
    if threshold_n <= 0 or min_contact_ms <= 0 or min_separation_ms <= 0:
        raise ValueError('Invalid force threshold / minimum durations')
    factor = {'s': 1e6, 'ms': 1e3, 'us': 1.}[time_unit]
    events, above = [], None
    last_time = None
    with Path(path).open(newline='', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        for col in (time_field, force_field):
            if col not in (reader.fieldnames or []):
                raise ValueError(f'Missing column {col!r} in {path}')
        for row in reader:
            t = round(float(row[time_field])*factor)
            force = float(row[force_field])
            if last_time is not None and t <= last_time:
                raise ValueError('Nonmonotonic force trace')
            last_time = t
            if not math.isfinite(force):
                raise ValueError('Nonfinite force trace')
            if force > threshold_n:
                if above is None: above = t
            elif above is not None:
                if t-above >= min_contact_ms*1000:
                    if not events or above-events[-1]>=min_separation_ms*1000:
                        events.append(above)
                above = None
    return events  # truncated open-last-contact excluded intentionally


def compare_events(predicted, reference, tolerance_ms=50, offset_ms=0):
    """Monotonic maximum-cardinality matching; no reference can match twice."""
    if tolerance_ms < 0 or not math.isfinite(offset_ms):
        raise ValueError('Bad tolerance/offset')
    p = sorted(round(t + offset_ms*1000) for t in predicted)
    r = sorted(reference)
    if len(set(p)) != len(p) or len(set(r)) != len(r):
        raise ValueError('Repeated event timestamps')
    tol = tolerance_ms * 1000
    i=j=0
    errors = []
    while i < len(p) and j < len(r):
        delta = p[i]-r[j]
        if abs(delta) <= tol:
            errors.append(delta/1000)
            i+=1; j+=1
        elif delta < -tol:
            i+=1
        else:
            j+=1
    tp=len(errors); fp=len(p)-tp; fn=len(r)-tp
    precision=tp/len(p) if p else None
    recall=tp/len(r) if r else None
    f1=2*tp/(2*tp+fp+fn) if tp or fp or fn else None
    return {'predicted_events':len(p),'reference_events':len(r),
            'matched':tp,'false_positive':fp,'false_negative':fn,
            'precision':precision,'recall':recall,'f1':f1,
            'timing_mae_ms':sum(abs(x) for x in errors)/tp if tp else None,
            'match_tolerance_ms':tolerance_ms,'offset_ms':offset_ms,
            'warning':'Metrics apply only to independently aligned/annotated references, not activity labels.'}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--predicted', type=Path, required=True, help='GaitLab steps.csv')
    p.add_argument('--reference', type=Path, required=True)
    p.add_argument('--reference-force', action='store_true', help='Reference file contains vertical GRF samples')
    p.add_argument('--reference-time-column', default='timestamp')
    p.add_argument('--reference-time-unit', choices=['s','ms','us'], default='s')
    p.add_argument('--force-column',default='Force_Z')
    p.add_argument('--threshold-n',type=float,default=50)
    p.add_argument('--offset-ms',type=float,default=None,
                   help='REQUIRED: alignment correction from predicted to reference clock, even if zero')
    p.add_argument('--tolerance-ms',type=float,default=50)
    p.add_argument('--out',type=Path)
    args=p.parse_args()
    if args.offset_ms is None:
        p.error('Specify --offset-ms explicitly: zero only if the CSV clocks are already synchronized')
    predicted=read_event_times(args.predicted,'event_timestamp_us','us')
    reference=(force_contacts(args.reference,args.reference_time_column,args.force_column,
                              args.reference_time_unit,args.threshold_n)
               if args.reference_force else
               read_event_times(args.reference,args.reference_time_column,args.reference_time_unit))
    result=compare_events(predicted,reference,args.tolerance_ms,args.offset_ms)
    print(json.dumps(result,indent=2))
    if args.out:
        args.out.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')

if __name__ == '__main__':
    main()
