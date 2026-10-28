# GaitLab — instructions for coding agents

## Goal and architecture
Build a **Flutter/Dart cross-platform research tool** for a phone tightly mounted in the center of a running belt (preferably rear waist). Capture raw accelerometer and gyroscope streams with native event timestamps; derive **candidate** step events, cadence, interval CV, periodicity, and signal-quality metrics. Keep the signal pipeline in `lib/gait_engine.dart` (pure Dart), acquisition/UI in `lib/main.dart`, recording/export in `lib/session_recorder.dart`, and independent offline QA in `tools/`.

Read `README.md`, `PUBLIC_DATASETS.md`, `VALIDATION.md`, and `docs/ROADMAP.md` before substantial changes. Work in the current checkout: do **not** reimport an old ZIP or overwrite generated platform runners unintentionally.

## Accuracy and reproducibility
- The device is **not** a medical device. Do not claim real foot contacts, ground-contact time, left/right attribution, true vertical displacement, injury prediction, or validated gait asymmetry.
- Preserve raw x/y/z, sensor-native timestamps, separate accelerator/gyro streams, exported schema, metadata, and processing parameters. Avoid asserting both sensor streams are precisely synchronized.
- Distinguish **activity-label smoke tests** from reference-annotated event accuracy. Existing AZI350 trials have running/sitting labels but no true per-step labels; they are also pocket-carried rather than belt-mounted.
- Preserve signal-quality rules for dropout, rate changes, flipped orientation, stationary segments, double peaks, starts/stops, and vibration. A high periodicity score does not establish correct step counts.
- Never silently substitute synthetic input for downloaded public research data. Public files must be acquired on demand, integrity-checked, and excluded from git.
- For every proposed biometric metric: state its physical meaning, assumptions, how it is measured, uncertainty, and validation against independent ground truth.

## Development and checks
- First establish a runnable baseline: `bash scripts/bootstrap.sh` then `bash scripts/verify_local.sh`.
- After Dart edits: `flutter analyze`, `flutter test`. After Python changes: `python3 -m unittest discover -s tools -p 'test_*.py' -v`. After changing mobile integration: build the relevant platform and test on hardware.
- Before declaring public replay validated: `python3 tools/public_datasets.py --fetch`, then run `dart run tools/replay_public.dart` for running and sitting trials. No internet means **NOT RUN**, not PASS.
- When fixing a bug, add or update a regression test. Report exact commands executed and exit status, and classify as PASS / FAIL / NOT RUN. Do not conflate static analysis, build, real-device evidence, or biomechanical accuracy.
- iOS requires macOS + Xcode. Linux Codex Cloud can do Dart tests and (with Android SDK) Android builds, but cannot physically test the user's phone.
- App intentionally records only in the **foreground** for v0.4; don't claim background recording works.

## Working agreement
- Prefer small, reviewable changes and maintain `CHANGELOG.md` and `VALIDATION.md` with actual evidence.
- Don't push, merge, create releases, publish stores, change repo visibility, or introduce secrets unless the user explicitly asks.
- Use existing dependencies or document why a new one is necessary. Keep a local-only, offline path for QA; do not add an API backend without a requirement.
- Treat model selection as a user preference (Sol High for implementation; Astra High for critical review), not as proof of correctness. Project `.codex/config.toml` only applies if the user's Codex client trusts project config.
- For first local task: prioritize passing CI and physical-device install before advanced new gait metrics.
