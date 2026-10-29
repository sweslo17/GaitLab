# GaitLab — research decisions and next milestones

## Product decisions (2026-10-28)
- Main user: runner with a phone fixed in a running waist belt, ideally rear center. Both Android and iOS supported.
- Flutter UI and shared pure-Dart gait engine; phone accelerometer + gyroscope, target ~100 Hz, measure actual sample rate and dropouts.
- v0.7: Android uses a user-started health foreground service and CPU wake lock for screen-off recording. iOS remains foreground-only. No automatic recording restart after force stop or process death.
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

## v0.5 local implementation evidence (2026-10-28)

Optional cadence targets, one-second trend charts, time-weighted quality coverage and seven-file export are implemented. Android installation and a 31-second foreground recording on Samsung SM S9210 pass file-integrity checks. See VALIDATION.md and validation/device_smoke_2026-10-28.json. This is acquisition evidence; actual belt-mounted running count and event accuracy remain unverified.

## v0.8 exploratory motion signals (2026-10-28)

Motion-state timeline, vector acceleration/gyro RMS and conditional rear-waist direction calibration are implemented. They are experimental signal descriptors, not validated walk/run labels, route turns or pelvis kinematics. The raw detector is unchanged. Next scientific gate: synchronized video activity intervals, reference IMU/motion capture, repeated mounting calibration, and unplugged long-duration recording with battery measurement. See FEATURE_STATUS.md, METRIC_ASSESSMENT.md and VALIDATION.md.
