# GaitLab v0.4.0 — verification record (2026-10-28)

## Checkpoint and startup cache correction (2026-10-29)

The latest source includes the post-device-test acquisition correction. Its physical reinstall/re-record is **NOT RUN**. Earlier installation and screen-off evidence do not validate this final source. Resume instructions: [development handoff](docs/DEVELOPMENT_HANDOFF.md).

- Observed failure: a cached first accel and gyro belonged to the prior recording. In the controlled v0.8 capture, this inflated sensor span to321.539841s, including167.528255s before the first fresh acceleration event. Entire-session duration correctness — FAIL; [reproduction evidence](validation/motion_startup_cache_reproduction_2026-10-28.json).
- The separately observed94-second non-interactive USB screen-off interval continued collecting10,753 acceleration and10,751 gyro CSV rows, with the CPU lock held at both observations. This limited continuity evidence does not repair the full-session duration failure.
- Gate regression tests reproduce stale-cache anchoring, independent streams, raw preservation/rejection counts and wall-clock changes between subscriptions. The source now carries previous native stream watermarks; the initial subscription alone uses the documented100ms epoch assumption. Raw samples and detector parameters are preserved.
- Offline production-code replay of the actual failed capture with the initial gate reduces derived span to154.011586s,17664 accepted acceleration samples, and one stale event excluded from each stream. This is replay evidence, not a physical retest.
- `poetry run bash scripts/verify_local.sh` — PASS, exit 0: 40 Python tests, Flutter analyze with no issues, 84 Flutter tests (`/tmp/gaitlab-checkpoint-verify.log`). `git diff --check` — PASS, exit 0. `flutter build apk --debug --target-platform android-arm64` — PASS, exit 0 (`/tmp/gaitlab-checkpoint-build.log`). Final APK SHA256 and verification evidence: [checkpoint record](validation/checkpoint_2026-10-29.json). Physical installation/re-record of this final fix remains NOT RUN. Human biomechanical accuracy and unplugged endurance remain NOT RUN.

## v0.8 motion signal analysis (2026-10-28)

- `flutter analyze` — PASS, exit 0, no issues (`/tmp/gaitlab-motion-analysis.log`). `flutter test` — PASS, exit 0, 77 tests (`/tmp/gaitlab-motion-tests.log`).
- Pure Dart tests cover known directional energy/ratios, gyro units, independently timed coverage, missing/stale gyro, sensor callback ordering, delayed gyro before calibration, final partial-bin clipping, long compact gaps, calibration failure/invalidation, early stop and numerical input guards. Engineering fixtures are synthetic and explicitly separate from the public-data smoke test.
- File regression tests preserve the seven exported files and original raw schemas while adding optional nested motion bins/parameters. UI tests include empty, calibrating, failed and ready states; ready directional bars and expanded plots fit 320px at 1.6x text without exceptions.
- Independent read-only review found no remaining important issue. Early-finish calibration status and latest-unavailable wording were reproduced in failing tests, then fixed. The original detector source prefix is byte-identical to HEAD; no parameter tuning.
- `dart run /tmp/gaitlab-motion-public.dart` — PASS, exit 0, three authentic, SHA256-checked AZI350 normalized participant001 pants-pocket trials: sitting, walking and running. Acceleration-only inputs explicitly omit gyro and disable body calibration. Running shows 7.581 seconds of rhythmic signal, walking 14.728 seconds of other movement, sitting remains unavailable without gyro. This is execution evidence, not a walk/run classifier score. [Public smoke evidence](validation/motion_public_smoke_2026-10-28.json).
- `flutter build apk --debug --target-platform android-arm64` — PASS, exit 0 (`/tmp/gaitlab-motion-build.log`). Final `adb -s RFCX502Z2JZ install -r build/app/outputs/flutter-apk/app-debug.apk` and launch — PASS, exit 0. This earlier installed build predates the final startup-cache correction; see the checkpoint section above.
- Human body-frame accuracy, motion-state F1, matched reference angular speed, belt-mounted running accuracy, unplugged endurance and battery use — NOT RUN. All thresholds and calibration assumptions remain experimental. iOS background recording remains unsupported.

## v0.7 Android screen-off recording (2026-10-28)

- `flutter analyze` — PASS, exit 0, no issues (`/tmp/gaitlab-background-analysis.log`).
- `flutter test` — PASS, exit 0, 58 tests (`/tmp/gaitlab-background-tests.log`). Regression tests cover writes during pending flush, concurrent close, native startup confirmation, cancellation, notification stop callbacks and lifecycle policy. The flush/write regression failed before the buffered writer fix.
- `flutter build apk --debug --target-platform android-arm64` — PASS (`/tmp/gaitlab-background-build.log`). `adb -s RFCX502Z2JZ install -r build/app/outputs/flutter-apk/app-debug.apk` — PASS, exit 0. Samsung SM S9210, Android 16 / API 36 reports 0.7.0+7; installed APK SHA256 matches the final build.
- Hardware screen-off continuity — PASS for this USB-connected smoke test. After recording began and notification permission was allowed, `adb shell input keyevent KEYCODE_SLEEP` made the phone non-interactive (`mWakefulness=Dozing`, Samsung always-on display). Observations 63 wall-clock seconds apart show the recording CPU partial wake lock held and both raw streams increasing. The native sensor-time window spans 62.954091 s with 7,220 samples in each independent stream.
- Entire capture: 178.545985 s sensor span, 20,478 accelerometer samples, 20,473 gyro samples, no rejected acceleration samples, no non-increasing timestamps. Maximum consecutive gaps: acceleration 8.726 ms, gyro 8.723 ms; median rate about 114.69 Hz. Streams remain separate; equal nominal rates do not establish synchronization.
- Notification action **停止並儲存** — PASS on the locked phone's expanded notification. Seven files and summary were saved with the notification stop reason. Follow-up `adb shell dumpsys activity services dev.gaitlab.gaitlab` reports `(nothing)` and `dumpsys power` has no held `GaitLab:Recording` partial wake lock. App-process logcat has no Flutter error, fatal exception or bound-sink write error.
- Raw smoke files remain local at `/tmp/gaitlab-screenoff-session`. Compact evidence: [screen-off record](validation/screen_off_2026-10-28.json).
- `poetry run python tools/analyze_session.py /tmp/gaitlab-screenoff-session --out /tmp/gaitlab-screenoff-qa.json` — PASS, exit 0, `integrity_ok: true`, zero sampling gaps. Independent raw timestamp checks also verify gyro ordering and the screen-off sample window. `git diff --check` — PASS, exit 0.
- Unplugged endurance, battery use, other Android devices, process-death recovery and iOS background recording — NOT RUN. iOS remains foreground-only. This stationary test has no independent step reference and does not validate gait accuracy.

## v0.6 personal trend readability (2026-10-28)

- `flutter analyze` — PASS, exit0, no issues (`/tmp/gaitlab-trend-analysis.log`).
- `flutter test` — PASS, exit0,49tests (`/tmp/gaitlab-trend-tests.log`), including fixed windows, gap coverage, zero baselines, CV units and320px layout with1.6x text.
- `flutter test test/session_recorder_test.dart` — PASS, exit0,2tests after adding comparison-export assertions (`/tmp/gaitlab-trend-export-tests.log`).
- Independent read-only review found no actionable comparison, unit or readability issue.
- `flutter build apk --debug --target-platform android-arm64` — PASS, exit0 (`/tmp/gaitlab-trend-build.log`).
- `adb -s RFCX502Z2JZ install -r build/app/outputs/flutter-apk/app-debug.apk` and launch — PASS, exit0, Samsung SM S9210 reports0.6.0+6. Installed APK SHA256 matches the final build.
- Phone visual inspection during this update — NOT RUN: phone locked. Widget checks cover ready, withheld and collecting results at320px with1.6x text; priorv0.5 physical sensor capture remains documented separately. Evidence: [trend readability](validation/trend_readability_2026-10-28.json).
- The detector and raw export headers are unchanged. The5% cadence guard is exploratory, and no matched-speed, fatigue or gait-improvement claim is made.


## v0.5 session metrics — local feature checks (2026-10-28)

- Baseline: `poetry run bash scripts/bootstrap.sh` and `poetry run bash scripts/verify_local.sh` — PASS, exit 0.
- `flutter analyze` — PASS, exit 0, no issues (`/tmp/gaitlab-feature-analysis.log`).
- `flutter test` — PASS, exit 0, 34 tests including time-weighted metrics, gaps, target controls, narrow layout and seven-file exports (`/tmp/gaitlab-feature-tests.log`).
- `poetry run python -m unittest discover -s tools -p 'test_*.py' -v` — PASS, exit 0, 40 tests (`/tmp/gaitlab-feature-python.log`).
- `flutter build apk --debug --target-platform android-arm64` — PASS, exit 0 (`/tmp/gaitlab-feature-build.log`). Existing Java startup was slow; Gradle completed successfully.
- Independent product-code review — no remaining actionable findings. The original detector source is unchanged; the new pure Dart classes are additive.

Foreground-only recording remains. The new UI, metric definitions and metadata do not establish running accuracy, contact time, asymmetry or injury prediction. Device installation and smoke-test evidence:

- Samsung SM S9210, Android 16 / API 36: `adb -s RFCX502Z2JZ install -r build/app/outputs/flutter-apk/app-debug.apk` — PASS, exit 0; package reports versionName 0.5.0 and versionCode 5.
- `adb -s RFCX502Z2JZ shell am start -n dev.gaitlab.gaitlab/.MainActivity` — PASS, exit 0. Target controls and plots inspected on hardware; recording disables target edits.
- Real foreground capture: 30.72019 s recording, 3520 accepted accelerometer samples and 3519 independent gyro samples; no rejected samples or detected sampling gaps. Median acceleration rate 114.68 Hz.
- Seven files exist, including 31 metric bins whose durations sum to the native 30.68438 s signal span. Target settings are present in both metadata and summary; target percentage stays null without eligible cadence time.
- `poetry run python tools/analyze_session.py /tmp/gaitlab-v05-device-session --out /tmp/gaitlab-v05-device-qa.json` — PASS, exit 0, integrity_ok true. Raw QA files remain local in /tmp. Compact evidence: [device smoke record](validation/device_smoke_2026-10-28.json).
- App-specific logcat inspection found no Flutter exception, overflow or fatal runtime error during this smoke test. There is no independent reference count for the three candidate events in this session; running accuracy is NOT RUN.


## Local public-data benchmark — 2026-10-28 (latest evidence)

This section supersedes the older packaging-environment NOT RUN statements below. Full evidence, provenance and exclusions: [dataset report](docs/DATASET_VALIDATION_2026-10-28.md). Results: [machine summary](validation/dataset_benchmark_2026-10-28.json).

- `bash scripts/bootstrap.sh` — PASS, exit 0 after allowing the existing Flutter SDK cache writes. The initial sandbox attempt exited 1.
- `poetry install` — PASS, exit 0 after repairing concurrent environment creation; Python 3.14, NumPy and SciPy. Initial environment creation failed; no application dependencies changed.
- `poetry run bash scripts/verify_local.sh` — PASS, exit 0. Includes 39 Python tests, Flutter analysis with no issues and 19 Flutter tests. A later `poetry run python -m unittest discover -s tools -p 'test_*.py' -v` also passes all 40 Python tests (exit 0) after the Cambridge boundary-sensitivity regression test was added. Full local output: `/tmp/gaitlab-final-verification.log`.
- `poetry run python tools/inspect_running_imu.py --export` — PASS, exit 0; source hashes and 173 exports.
- `poetry run python tools/inspect_zenodo.py` and `poetry run python tools/prepare_zenodo_replay.py` — PASS, exit 0; source MD5, archive CRC and conversion.
- `poetry run python tools/prepare_clemson.py`, `poetry run python tools/prepare_walkrec.py`, `poetry run python tools/prepare_cambridge.py`, and `poetry run python tools/normalize_azi350.py` — PASS, exit 0; exact source/representation assumptions recorded in local manifests.
- `dart run tools/replay_normalized.dart reports/public/azi350_replay_inputs.json reports/public/azi350_replay.json` — PASS, exit 0, 646 trials. Broad activity negative controls FAIL: sitting 26/82 and standing 32/86 trials emit candidates. The agent used the installed SDK binary directly after the wrapper cache restriction.
- `dart run tools/replay_normalized.dart reports/public/running_imu_replay_inputs.json reports/public/running_imu_replay.json` — PASS, exit 0, 173 trials; no event/count accuracy labels.
- `dart run tools/replay_normalized.dart reports/public/zenodo_replay_manifest.json reports/public/zenodo_replay.json` — FAIL, exit 1: 1125/1126 trials execute; one Apple trial has a non-increasing source timestamp. Original is retained and the trial is not silently repaired.
- `dart run tools/replay_normalized.dart reports/public/clemson_replay_inputs.json reports/public/clemson_replay.json` — PASS, exit 0, 90 trials; two reference-window inconsistencies withheld from count scoring.
- `dart run tools/replay_normalized.dart reports/public/cambridge_replay_inputs.json reports/public/cambridge_replay.json` — PASS, exit 0, 132 trials; 117 reference-window comparisons. Four endpoint conventions give the same candidate counts.
- `dart run tools/replay_normalized.dart reports/public/walkrec_inputs.json reports/public/walkrec_replay.json` — PASS execution, exit 0, 142 trials. 120 count comparisons; references are leg-phone detections/corrected counts. Fifteen count conflicts and seven time-coverage mismatches are withheld.
- `poetry run python tools/summarize_benchmarks.py` — PASS, exit 0. Absolute errors are aggregated before division, so opposite signed errors cannot cancel.
- `dart run tools/replay_normalized.dart /tmp/gaitlab-empty-manifest.json /tmp/gaitlab-empty-output.json` — expected rejection, exit 2, no empty benchmark success claim.
- `git diff --check` — PASS, exit 0.

New tests were checked failing before implementation, including incompatible gravity, scoring eligibility, reference-window counts, invalid reference indices and error aggregation. The engine and parameters were not changed. Real-device capture, native builds, held-out running accuracy and contact-event F1 remain NOT RUN for this task.

## Historical packaging-environment evidence

- Python 3.13 standard library: `python3 -m unittest discover -s tools -p 'test_*.py' -v` — **18 tests PASS**.
- 3,000 randomized event matching cases checked against dynamic-programming maximum bipartite matching on a line — **PASS**. This strengthens the event scorer's one-to-one count matching but does not verify physiological correctness.
- `python3 -m compileall -q tools` — **PASS**.
- `bash -n scripts/bootstrap.sh scripts/verify_local.sh` — **PASS**.
- `.github/workflows/verify.yml` parsed using PyYAML; three job keys found — **PASS** (NOT equivalent to executing CI).
- Public dataset exploratory analysis: **three authentic, unmodified CSV contents** retrieved via connected GitHub tool, processed **in JavaScript translation of peak rule**, output saved in `validation/public_exploratory_scan.json` and described in `PUBLIC_DATASETS.md`. **No per-step reference labels** in these 3 files.
- New source pinned: source Git blob hashes from GitHub repository metadata, no user-controlled or rewritten data bundled.

## Codex-ready baseline: observed CI success (2026-10-28)

- Workflow: https://github.com/sweslo17/GaitLab/actions/runs/40622511044 — **SUCCESS** on commit `1e4584b6454b159c7965e161bd8de900b764c8b9`.
- **Android**: temporary native runner generated; `flutter analyze` PASS; `flutter test` PASS; Python unit tests PASS; `flutter build apk --debug` PASS.
- **iOS**: native runner generated on macOS; `flutter analyze` PASS; `flutter test` PASS; `flutter build ios --simulator --no-codesign` PASS.
- **Public-data Dart replay**: pinned source download and SHA verification PASS; running pants, sitting negative control and running upper-pocket PASS through production GaitEngine.
- These CI results **do not** test actual phone IMU capture, iPhone device signing, Codex Cloud SDK installation, independent ground-contact truth, or scientific step accuracy.

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

Passing code-quality checks or a running-versus-sitting example does not establish correct cadence, event timing, ground contact time, injury status or clinical performance. Public dataset transfer from 50 Hz pants/upper-pocket phone data to a waist-belt phone is not guaranteed. That packaging snapshot is historical; the latest local and CI evidence above supersedes its execution status.

## To complete next gate

1. `python3 tools/public_datasets.py --fetch --out reports/public/source_manifest.json` on a development or CI machine with internet access.
2. `dart run tools/replay_public.dart --file data/public/azi350/running_pants.csv --activity running` and repeat on sitting and upper-pocket trial; run CI job on commit.
3. Acquire and align independent reference recordings (OptoJump / force plate / manually marked video) and score matched events with `tools/score_events.py`.
4. Validate on real belt-mounted phones from >1 participant and >1 device at multiple paces, include failure cases and confidence intervals.
