# GaitLab — research decisions and next milestones

## Product decisions (2026-10-28)
- Main user: runner with a phone fixed in a running waist belt, ideally rear center. Both Android and iOS supported.
- Flutter UI and shared pure-Dart gait engine; phone accelerometer + gyroscope, target ~100 Hz, measure actual sample rate and dropouts.
- v0.4: foreground-only on both platforms; stop cleanly on background/lost sensor feed. Android background foreground-service recording is a **future feature**, not implemented.
- Candidate peak timestamps, cadence, step-time CV, vertical-axis dynamic acceleration and periodicity are **experimental movement characteristics**, not medical gait metrics.
- Raw events and metadata retained for reproducibility; separate independent streams rather than false accelerometer/gyro synchronization.
- Python standard-library QA and optional plotting (uv-friendly); no web service, account, or telemetry upload.

## Provenance, research and experimental validation
- `PUBLIC_DATASETS.md` lists AZI350 phone running/sitting activity controls (50–53 Hz, different pocket placements), Running_IMU with OptoJump references, and Apple Watch waist IMU with force-plate contact references.
- The public-pockets dataset supplies **activity labels, not reference contact times**; it can test the pipeline and detect gross false positives only.
- The 2026 Running_IMU dataset has high-speed (15–25 km/h) research IMUs; Apple Watch waist data is not a waist-mounted phone. Explicitly handle acceleration units, gravity, offsets, left/right scope and contact coverage before event scoring.
- Do not infer left/right legs, absolute oscillation, ground-contact duration, or injury prediction from a single generic waist-mounted phone.

## Milestones (in order)
1. **Reliable build baseline**: eliminate analyzer issues, pass Flutter tests on Android/macOS, create both native runners safely, obtain real Android debug APK and iOS simulator build.
2. **Reproducible data replay**: run downloaded, hash-checked AZI350 trials through production Dart in CI; document counts, sample rates and negative control, not footstrike accuracy.
3. **Device validation**: use physical belt-mounted Android and iPhone, measure event-rate jitter, recording behavior and exports; manually annotated step counts from multiple runs.
4. **Independent biomechanics ground truth**: align force/OptoJump annotations or video contact times to inertial recordings; score precision, recall, F1, timing MAE and per-person error with held-out devices/subjects.
5. **Only then improve advanced metrics**: evaluate fatigue-related timing trends, optional multi-IMU configuration, and background recording strategy.

## Engineering acceptance goals (not achieved claims)
- Proposed target: step-count error ≤2%; median cadence error ≤3 spm; contact-event F1 ≥0.90 at ±50 ms **only when independently synchronized truth supports it**.
- Separate performance by pace, hardware, belt placement and participant; show false positives from standing, turns, starts and stops.
- Do not tune detector parameters using the held-out evaluation subjects.
- Track PASS, FAIL and NOT RUN in `VALIDATION.md` and link a CI run or local command output for every new claim.
