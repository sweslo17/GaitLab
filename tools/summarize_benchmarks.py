"""Summarize actual replay results without cancelling count errors across trials."""
from collections import defaultdict
import json
from pathlib import Path
import statistics


def summarize(rows):
    good = [r for r in rows if r['replay_status'] == 'PASS']
    scored = [r for r in good if r.get('reference_count') is not None]
    result = {'trials': len(rows), 'replay_pass': len(good),
              'replay_fail': len(rows) - len(good), 'reference_scored_trials': len(scored),
              'candidate_steps': sum(r['candidate_steps'] for r in good),
              'nonzero_trials': sum(r['candidate_steps'] > 0 for r in good)}
    if scored:
        reference = sum(r['reference_count'] for r in scored)
        predicted = sum(r.get('candidate_steps_in_reference_window', r['candidate_steps']) for r in scored)
        percentages = [abs(r['count_error_percent']) for r in scored if r.get('count_error_percent') is not None]
        result.update(reference_steps=reference, predicted_steps_in_scored_windows=predicted,
                      signed_total_error_percent=100 * (predicted - reference) / reference if reference else None,
                      weighted_absolute_error_percent=100 * sum(abs(r['count_error']) for r in scored) / reference if reference else None,
                      median_absolute_trial_error_percent=statistics.median(percentages) if percentages else None)
    return result


def main():
    output = {'date': '2026-10-28', 'engine': 'Unchanged production GaitEngine, peakMultiplier 0.62',
              'warning': 'Replay PASS means execution only; references and input domain differ across datasets.',
              'datasets': {}, 'missing_reports': []}
    for name in ['clemson', 'zenodo', 'running_imu', 'azi350', 'walkrec', 'cambridge']:
        path = Path(f'reports/public/{name}_replay.json')
        if not path.exists():
            output['missing_reports'].append(str(path))
            continue
        rows = json.loads(path.read_text())['trials']
        groups = defaultdict(list)
        for row in rows:
            key = row.get('dataset', name) + '/' + str(row.get('condition', row.get('activity', 'all')))
            groups[key].append(row)
        output['datasets'][name] = {key: summarize(group) for key, group in sorted(groups.items())}
    target = Path('validation/dataset_benchmark_2026-10-28.json')
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(output, indent=2) + '\n')
    print(target)
    if output['missing_reports']:
        raise SystemExit('Missing benchmark reports; summary is incomplete')


if __name__ == '__main__':
    main()
