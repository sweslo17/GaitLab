# GaitLab v0.4.0 — verification record (2026-10-28)

## Executed in this environment

- Python 3.13 standard library: `python3 -m unittest discover -s tools -p 'test_*.py' -v` — **18 tests PASS**.
- 3,000 randomized event matching cases checked against dynamic-programming maximum bipartite matching on a line — **PASS**. This strengthens the event scorer's one-to-one count matching but does not verify physiological correctness.
- `python3 -m compileall -q tools` — **PASS**.
- `bash -n scripts/bootstrap.sh scripts/verify_local.sh` — **PASS**.
- `.github/workflows/verify.yml` parsed using PyYAML; three job keys found — **PASS** (NOT equivalent to executing CI).
- Public dataset exploratory analysis: **three authentic, unmodified CSV contents** retrieved via connected GitHub tool, processed **in JavaScript translation of peak rule**, output saved in `validation/public_exploratory_scan.json` and described in `PUBLIC_DATASETS.md`. **No per-step reference labels** in these 3 files.
- New source pinned: source Git blob hashes from GitHub repository metadata, no user-controlled or rewritten data bundled.

## GitHub Actions observation (first v0.4 push)

- Run: https://github.com/sweslo17/GaitLab/actions/runs/40620643787 — **FAILED overall**.
- `public-dataset-replay`: **PASS** (download + SHA-verified AZI350 trials, 3 official Dart replays). This proves replay/smoke criteria only, not real contact accuracy.
- `android` and `ios`: **FAILED** at `flutter analyze` because of 8 lint warnings (`unnecessary_import`, `curly_braces_in_flow_control_structures`, `avoid_relative_lib_imports`). Platform builds and Flutter tests were not reached.
- The repository bootstrap/Codex fix commit addresses these issues. **Do not claim success until a new workflow run finishes.**

## Not executed

- `dart run tools/replay_public.dart` with downloaded data: **NOT RUN**, since Dart SDK is unavailable locally.
- `flutter test`, `flutter analyze`: **NOT RUN**.
- Android APK or iOS simulator/device builds: **NOT RUN**.
- Running_IMU data vs OptoJump or Apple Watch data vs force-plate step contacts: **NOT RUN** (large data archives cannot be downloaded in packaging environment; complete running alignment and gravity compatibility analysis required).
- Real smartphone fixed in waist belt, with manual video step labels: **NOT RUN**.

## Interpretation

Passing code-quality checks or a running-versus-sitting example does not establish correct cadence, event timing, ground contact time, injury status or clinical performance. Public dataset transfer from 50 Hz pants/upper-pocket phone data to a waist-belt phone is not guaranteed. The only existing real-data test is an exploratory independent detector translation; the production Dart replay job is **included but unexecuted**.

## To complete next gate

1. `python3 tools/public_datasets.py --fetch --out reports/public/source_manifest.json` on a development or CI machine with internet access.
2. `dart run tools/replay_public.dart --file data/public/azi350/running_pants.csv --activity running` and repeat on sitting and upper-pocket trial; run CI job on commit.
3. Acquire and align independent reference recordings (OptoJump / force plate / manually marked video) and score matched events with `tools/score_events.py`.
4. Validate on real belt-mounted phones from >1 participant and >1 device at multiple paces, include failure cases and confidence intervals.
