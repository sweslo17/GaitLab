# GaitLab v0.8 — motion signal analysis (2026-10-28; checkpoint 2026-10-29)

- Add an exploratory motion-state timeline, time-weighted vector acceleration and gyro RMS, and expandable trends. Do not infer validated walking/running or route turns.
- Add optional rear-waist direction calibration with explicit mounting orientation, stationary checks, progress, failure reasons and tilt invalidation. Show directional RMS and squared-amplitude shares.
- Keep independent sensor timestamps, original detector and seven-file raw schemas. Export complete motion bins and provenance in nested JSON fields.
- Test delayed gyro clipping, incomplete calibration, numerical guards, gaps, projection energy and accessible result layouts.
- Reject previous-session startup sensor cache from derived metrics while preserving raw samples and explicit exclusions. Keep per-stream native watermarks across sessions. Physical retest of this last correction remains pending.
- Version native runner sources and Poetry locks, provision QA dependencies in CI, and add a development handoff.

# GaitLab v0.7 — Android screen-off capture (2026-10-28)

- Add a user-started Android health foreground service, ongoing notification, stop-and-save action and partial CPU wake lock. Keep the display free to sleep.
- Preserve Android sensor subscriptions during screen off; keep iOS foreground-only. Record the actual recording mode in metadata.
- Buffer CSV rows during periodic flush and serialize flush/close to prevent active sensor writes from failing. Add real-file regression tests.
- Clarify implementation status of the four proposed gait-analysis directions.
- Verify a 63-second non-interactive screen-off window on Samsung Android 16 over USB, raw file integrity, notification stop-and-save, and CPU lock release. Long unplugged recording remains untested.

# GaitLab v0.6 — readable personal trends (2026-10-28)

- Compare the first and latest eligible30-second windows, with time-weighted metrics and per-metric coverage checks.
- Show signal amplitude change, periodicity change and candidate interval variability in their correct units, with no good/bad gait score.
- Explain missing data and withhold motion comparisons when candidate cadence differs by more than5%; this guard does not establish matched speed.
- Put result summaries before charts, collapse recording settings, support large text and use Chinese chart semantics.
- Add comparison data and parameters to nested exports. Detector and raw CSV formats remain unchanged.

# GaitLab v0.5 — session trends (2026-10-28)

- Add optional personal cadence targets, a cadence timeline, time-weighted quality coverage and target-range summaries.
- Add experimental interval CV, filtered acceleration RMS and periodicity charts with explicit limits.
- Add `metrics.csv`, target metadata and nested session metrics while preserving existing raw CSV headers.
- Preserve the step detector and its parameters. Empty or low-quality event metrics remain unavailable.

# Unreleased — Codex development baseline (2026-10-28)

- Download and integrity-check seven public datasets, preserve originals outside git, and replay production Dart without parameter tuning.
- Add audited adapters, reference-window count comparison, withheld scores for incompatible references, and reproducible benchmark summaries.
- Record broad sitting/standing candidate triggers and walking count errors; do not equate replay execution with running accuracy.
- Add Poetry-managed NumPy/SciPy for MATLAB research files and document useful metrics beyond step count.

- Add repo-native Codex instructions, project-level model defaults, local/Cloud/macOS device workflow and research roadmap.
- Replace ZIP-first README bootstrap with a clone-first workflow.
- Correct eight CI analyzer lints identified by the first v0.4 GitHub Actions run.
- Make native Flutter runner generation non-destructive: generate into a temporary checkout and copy only missing native runners; preserve original app files and tests.
- Add optional Codex Cloud Linux Flutter installer and robust verification commands; explicitly separate Python, Dart, native build and physical-data validation status.

# GaitLab v0.4 changes

- Public dataset research and documented limitations in PUBLIC_DATASETS.md.
- Added public smartphone trial fetcher: verifies pinned Git blob SHA-1, does not bundle third-party data; script fails on missing/network changes.
- Added production-engine Dart CLI replay for running and sitting, used in optional GitHub Actions job. Does **not** misrepresent activity-only labels as step-count truth.
- Added independent contact scoring harness: one-to-one matches, precision/recall/F1/timing MAE, mandatory explicit alignment offset and optional force-plate onset extractor.
- 50–65 Hz now has a 'review' quality label rather than always 'unreliable'; <45 Hz remains unreliable. Unit test updated accordingly.
- Extended offline Python test suite; actual Dart replay, Android and iOS builds and on-belt accuracy remain pending execution.
