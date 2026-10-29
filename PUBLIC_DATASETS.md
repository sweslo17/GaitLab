# Public-data validation plan — v0.4

This project deliberately separates **replay/smoke testing** from **ground-truth event accuracy**. A running-activity label is **not** a stride/foot-contact label. **No public dataset can establish accuracy for a specific phone bouncing in an individual's belt.**

## Executed benchmark — 2026-10-28

All seven datasets discussed in this session are now downloaded locally. See [the actual results and limitations](docs/DATASET_VALIDATION_2026-10-28.md), [machine summary](validation/dataset_benchmark_2026-10-28.json), and [metric assessment](docs/METRIC_ASSESSMENT.md). The engine and detection parameters remain unchanged.

Full-data activity controls expose candidate triggers in 26/82 sitting and 32/86 standing AZI350 trials. This supersedes any inference from the earlier single sitting example. Replay success does not establish count accuracy. Running_IMU reference MAT contains stance/stride durations, not contact timestamps or complete counts. The Apple archive also differs from its published description; use the actual archive inventory before scoring.

Cambridge and Clemson supply independent reference counts. WalkRec supplies combined leg-phone detections and corrected counts, with source disagreements and window mismatches withheld. No running dataset in this run supports a defensible complete running-step accuracy score yet.

## Dataset source descriptions

| Dataset | Data and reference | Match to GaitLab | Limits | Download/license |
|---|---|---|---|---|
| Ghaffarzadeh et al., 2026 | ~100 Hz waist Apple Watch and 1 kHz force plate; jogging/running, 492 curated trials / 395 triad-complete | Partial force-contact investigation; no complete count truth | IMU is a waist-worn **watch**, not a phone; `userAcceleration` is *gravity removed*, unlike GaitLab raw acceleration | https://doi.org/10.5281/zenodo.17376717 — CC BY 4.0 |
| Lubrano et al., 2026 Running_IMU | Lower-back, foot, shank IMU at high speeds, and OptoJump | Stance/stride duration reference; no event timestamps in released MAT | 800 Hz research hardware and 15/20/25 km/h, different from a phone at easy pace; 97 MB .mat signals | https://github.com/MyriamLubrano/Running_IMU — MIT repo |
| Baker et al., 2025 | 15 runners, pelvis/thigh/shank/foot IMU; forceplates for some runs | Terrain generalization and force comparison | 312 MB archive; force not available outdoors | https://doi.org/10.5281/zenodo.16541185 — inspect license on use |
| AZI350 Self Phone Three Positions | Smartphone accelerometer, gyro, activity labels, 50–53 Hz trials including running/sitting | **Immediately replay into production GaitEngine** | Positions hand/pants/upper pocket, **not waist belt**, no true per-step contact labels | https://github.com/AZI350/Smartphone-IMU-Three-Positions-Dataset — CC BY-NC-ND 4.0 |
| UCI HAR smartphones | 30 participants, waist-mounted phone, 50 Hz activity data | Negative controls and placement | **Walking only, no running**; processed window tensors rather than raw continuous timeline | https://archive.ics.uci.edu/dataset/240 |
| TRIPOD | Walking IMUs and OptoGait ground truth | Future walking benchmark | **Files access restricted/request-only**, not immediately downloadable | https://zenodo.org/records/5070771 |

### Baseline now integrated (AZI350)

Unmodified trial CSVs are fetched on demand, **not packaged**, and verified against pinned Git blob SHA-1 values to prevent silent data changes. The trial source license is **CC BY-NC-ND 4.0**; avoid rehosting the data or sharing altered CSVs.

```bash
python3 tools/public_datasets.py --fetch --out reports/public/source_manifest.json
# Requires a recent Dart SDK / Flutter SDK:
dart run tools/replay_public.dart --file data/public/azi350/running_pants.csv --activity running --out reports/public/running_pants.json
dart run tools/replay_public.dart --file data/public/azi350/sitting_pants.csv --activity sitting --out reports/public/sitting_pants.json
dart run tools/replay_public.dart --file data/public/azi350/running_upper.csv --activity running --out reports/public/running_upper.json
```

The replay uses the **actual production Dart `GaitEngine`**, not a separate Python approximation. The test asserts only plausible running candidate activity, sitting negative control, expected rate, and no rejected timestamps. It outputs the candidate event times for inspection. This is NOT a step-count accuracy score because no true step/footstrike events are supplied.

The normal ~50–53 Hz smartphone trials previously appeared as *unreliable* simply because of a fixed 60 Hz cutoff. v0.4 now distinguishes **45–65 Hz lower-resolution but still analyzable** from **under 45 Hz unreliable**. This correction **does not prove** accuracy at low sampling rates.

The GitHub Actions `public-dataset-replay` job re-downloads the same pinned samples and runs Dart replay on each push/PR. Data are not checked into the repo. CI not executed in packaging environment.

### Quick independent exploratory scan — performed in analysis environment

Three unmodified GitHub CSVs were read using the connected GitHub content tool, and a **separate JavaScript translation of the peak heuristic** (not executable Dart) yielded:

| Trial | Raw rows | Duration | Rate (median interval) | Candidate peaks | Approximate median cadence |
|---|---:|---:|---:|---:|---:|
| participant_001/pants_pocket/running/trial_01.csv | 765 | 14.6 s | 52.6 Hz | 32 | 146.5 spm |
| participant_001/pants_pocket/sitting/trial_01.csv | 1029 | 19.7 s | 52.6 Hz | 0 | n/a |
| participant_001/upper_pocket/running/trial_01.csv | 770 | 14.7 s | 52.6 Hz | 32 | 139.5 spm |

The reproduction uses a single participant and no ground truth for actual contact times. **It is exploratory evidence, NOT passed automated Dart public-data validation.** Also, the original data places the device in pockets, not a waist belt, so the results cannot certify the intended use case.

### Independent contact-event accuracy (future data, scorer already implemented)

`tools/score_events.py` matches one candidate to at most one reference event and reports **precision, recall, F1, timing MAE**. Input timestamps **must be synchronized**. It refuses to infer the necessary time offset: `--offset-ms` is mandatory. A 50 N threshold and ≥80 ms stance can create a provisional reference from a force trace, but should be manually checked for the particular source.

```bash
python3 tools/score_events.py \
  --predicted /your/GaitLab/session/steps.csv \
  --reference /your/independent/reference_contacts.csv \
  --reference-time-column contact_ms --reference-time-unit ms \
  --offset-ms 0 --tolerance-ms 50 --out reports/public/event_score.json
```

When using the Apple Watch + forceplate dataset, first convert Apple Core Motion gravity-removed `userAccelerationX/Y/Z` into a *compatible* representation; **do not feed it unchanged into GaitEngine raw accelerometer input**. Validate both sensor time alignment and force-plate scope (single force plate may record only one contact of several). Do not infer a full step-count accuracy score from a single contact plate.

Suggested acceptance targets (not measured): total step count error ≤2%, median cadence error ≤3 spm, independently aligned event F1 ≥0.90 at ±50 ms, and failures stratified by speed, device placement and participant. Perform a held-out participant evaluation rather than tune and report on the same subjects.
