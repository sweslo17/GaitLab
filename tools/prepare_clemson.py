"""Prepare untouched synchronized Clemson hip signals for exploratory replay.

The source is 15 Hz, outside GaitLab's intended input domain. No upsampling.
Source values near 1 g support the explicit g-to-m/s² interpretation.
"""
from pathlib import Path
from zipfile import ZipFile
import csv
import hashlib
import io
import json

DATA_SHA256 = 'ce37832d5e234f6f014193a3a2af2f3162ab90905f303d473849512d690885da'


def reference_steps(text):
    steps, shifts = [], []
    previous = -1
    for line in text.splitlines():
        if not line.strip():
            continue
        index, label = line.split()
        if label not in {'left', 'right', 'leftshift', 'rightshift'}:
            raise ValueError(f'Unknown reference label: {label}')
        index = int(index)
        if index <= previous:
            raise ValueError('Reference indices must be nonnegative and strictly increasing')
        previous = index
        (shifts if label.endswith('shift') else steps).append(index)
    return steps, shifts


def main():
    source = Path('data/public/clemson/Data.zip')
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if digest != DATA_SHA256:
        raise ValueError('Archive differs from first acquired source SHA256')
    trials = []
    with ZipFile(source) as archive:
        if archive.testzip() is not None:
            raise ValueError('ZIP CRC failed')
        for member in archive.namelist():
            if not member.endswith('/steps.txt'):
                continue
            folder = member.rsplit('/', 1)[0]
            data_files = [n for n in archive.namelist()
                          if n.startswith(folder + '/') and n.endswith('.txt') and n != member]
            if len(data_files) != 1:
                raise ValueError(f'Ambiguous signal: {folder}')
            rows = [list(map(float, line.split())) for line in
                    archive.read(data_files[0]).decode().splitlines() if line.strip()]
            if any(len(row) != 9 for row in rows):
                raise ValueError('Expected wrist, hip, ankle xyz')
            steps, shifts = reference_steps(archive.read(member).decode())
            invalid_indices = [index for index in steps + shifts if index > len(rows)]
            target = Path('data/public/clemson/normalized') / (folder.replace('/', '_') + '.csv')
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open('w', newline='') as stream:
                writer = csv.writer(stream, lineterminator='\n')
                writer.writerow(['timestamp_us', 'ax', 'ay', 'az'])
                for i, row in enumerate(rows):
                    writer.writerow([round(i * 1e6 / 15), *(v * 9.80665 for v in row[3:6])])
            trials.append({'file': str(target), 'dataset': 'Clemson',
                'subject': folder.split('/')[0], 'condition': folder.split('/')[1],
                'gravity_included': True, 'acceleration_representation': 'source g interpreted as g, multiplied by 9.80665',
                'timestamp_source': 'Reconstructed index / 15Hz; synchronized source',
                'reference_count': None if invalid_indices else len(steps),
                'reference_source_full_step_count': len(steps),
                'accuracy_eligible': not invalid_indices,
                'reference_out_of_range_indices': invalid_indices,
                'reference_shift_count': len(shifts),
                'reference_definition': 'left/right full steps only; leftshift/rightshift excluded',
                'reference_window': 'entire source file including startup',
                'reference_index_note': 'Count scoring only; event index origin not assumed. Withhold scoring if any index exceeds signal rows.',
                'domain_warning': '15Hz is below supported 45Hz; exploratory domain stress test only',
                'source_file': data_files[0], 'reference_file': member})
    report = {'source': 'http://cecas.clemson.edu/tracking/Pedometer/Data.zip',
        'sha256': digest, 'integrity': 'ZIP CRC and locally pinned SHA256; no publisher checksum supplied; HTTP acquisition',
        'trials': trials}
    out = Path('reports/public/clemson_replay_inputs.json')
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2) + '\n')
    print(f'Prepared {len(trials)} original hip recordings')


if __name__ == '__main__':
    main()
