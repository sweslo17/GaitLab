# GaitLab v0.4 — Flutter running gait sensor research tool

Cross-platform Flutter **source project** for a phone tightly attached to the center of a running belt (rear waist preferred). Supports Android and iOS **foreground-only recording**. Not an APK/IPA or a clinically validated gait diagnosis device.

## Feature scope

- Accelerometer and gyroscope requested at 10 ms intervals (~100 Hz). Hardware/OS may deliver slower or irregular event rates; actual rate and estimated missing data are reported.
- Pure Dart candidate step peaks, recent median cadence, step interval, interval CV, gravity-axis dynamic acceleration waveform, normalized autocorrelation **periodicity proxy**.
- Signal quality status with an estimated **last-five-second** sample-loss percentage. This is **not** an algorithm accuracy metric.
- Sensor liveness watchdog, lifecycle-aware recording: screen remains on if `wakelock_plus` succeeds; entering the background ends the session, and extended accelerometer silence stops it.
- Six-file export with separate acceleration and gyroscope streams, event time stamps, candidate step timestamps, quality samples, metadata and summary.
- Python/uv CLI for independent QA, synthetic tests and optional plotting; optional GitHub Actions compilation workflow.

**Not measured:** actual foot strikes, ground contact time, left/right foot identity or loading, footstrike pattern, knee angles, running injury risk, absolute vertical oscillation or validated gait asymmetry.

## Prerequisites

- Flutter **3.47.7 or later** (Dart 3.13.5+) with Android SDK or macOS/Xcode for iOS. Android/iOS Flutter SDK requirements are platform specific.
- For iOS the bootstrap sets deployment target to **iOS 15** (current Flutter 3.47 supported platform baseline).
- Python 3.11+ for offline QA. Python scripts use only stdlib; optional plots need matplotlib.

## Get started

```bash
git clone https://github.com/sweslo17/GaitLab.git
cd GaitLab
git switch -c develop
bash scripts/bootstrap.sh
bash scripts/verify_local.sh
flutter devices
flutter run -d YOUR_DEVICE_ID
```

For Codex Local, open this checkout; Codex will read `AGENTS.md` and (if trusted) `.codex/config.toml`. For Codex Cloud, see [Codex setup](docs/CODEX_SETUP.md). For algorithm design and next validation milestones, see [roadmap](docs/ROADMAP.md). **No ZIP or GitHub Release is required.**

`bootstrap.sh` generates only **missing** native `android/` and (on macOS) `ios/` folders via a temporary `flutter create` project without overwriting tracked files, applies `NSMotionUsageDescription` and the iOS deployment target, and resolves dependencies. The package includes its Dart sources and tests, **not generated native runners**. On iOS, Xcode and device signing are required for a physical device.

The verify script returns a **nonzero error** if Flutter is unavailable; it does not silently mark Dart checks as passed. To run only executable Python checks:

```bash
bash scripts/verify_local.sh --python-only
```

The `.github/workflows/verify.yml` CI creates Android and iOS runners and requests `flutter analyze`, `flutter test`, Android debug APK build and iOS simulator build after pushing the folder to GitHub. **The CI workflow has not been run in this environment.**

## Recording test protocol

1. Tighten the waist belt so the phone cannot bounce inside it; choose `後腰中央` unless another consistent position is required.
2. Start while the app stays open. The detector ignores the first **0.6 seconds**; no left/right foot identity is assigned.
3. Stand still 10 seconds, walk 30 seconds, run 2–3 minutes at a comfortable pace. Count or independently film the actual steps on a defined window. Then try 20+ minutes and a range of paces.
4. Stop, export six files, and verify the raw timestamps plus the candidate peaks. Repeat with the same phone placement.
5. Avoid treating a high periodicity coefficient as proof of accurate step detection; check manually annotated count and timing, especially while turning, starting/stopping, or when the belt is loose.

The app stops when backgrounded to avoid pretending to record continuously on an unsupported operating system path. There is **no Android foreground service** in this version and no iOS guaranteed background IMU feed.

## Output schema

Files saved to application documents `GaitLab/<UTC session start>/` and shared with the OS share sheet:

| File | Content |
|---|---|
| `accelerometer.csv` | independent raw x/y/z in m/s², projected dynamic acceleration, filter output, dynamic threshold, accepted flag, native-event timestamp represented as epoch microseconds |
| `gyroscope.csv` | x/y/z in rad/s and independent event timestamps; no false row-level synchronization with accelerometer |
| `steps.csv` | acceleration-derived **candidate** peak timestamps, optional interpeak durations and estimated cadence |
| `quality.csv` | sampling rate, RMS, autocorrelation, lifetime estimated missing %, recent (5 s) missing %, interruption count, grade, reason |
| `metadata.json` | app version, belt placement, requested rate, detection parameters, timestamp source |
| `summary.json` | session totals, last-window feature values, completion reason, validation warning |

The app uses `sensors_plus` `DateTime` event timestamps without claiming submillisecond precision or that acceleration and gyro streams are perfectly synchronized.

## Python QA, reference count and plots

```bash
python3 tools/analyze_session.py /path/to/session \
  --start-seconds 40 --duration-seconds 120 \
  --reference-steps 340 --reference-spm 170 --out qa.json

# Equivalent with installed uv:
uv run --offline tools/analyze_session.py /path/to/session --out qa.json

# Optional plot, if matplotlib is already installed:
python3 tools/plot_session.py /path/to/session \
  --offset 20 --seconds 12 --save trace.png
```

The QA script checks raw sample timestamps, every candidate peak against the original accepted acceleration stream, recorded step intervals, required files, and summary counts. It also estimates sample loss and optional manual-reference cadence/count error. The ≤2% step-count and ≤3 spm criteria proposed earlier are **targets, not established accuracy claims**. Data-integrity success does not prove biomechanical correctness.

## Verification status

- The source and Python scripts have been reviewed; Python tests and shell syntax checks have been executed in the packaging environment.
- This environment lacks Flutter/Dart, Android SDK, Xcode and physical phones, and cannot fetch Flutter binaries. Therefore **Flutter analysis, Flutter unit/widget tests, Android APK and iOS simulator/device builds are not verified here**.
- GitHub CI is provided for those next compilation gates, but it must actually run; copying a workflow into the project does not count as a passing build.
- Accuracy of cadence, count and step-event timing requires synchronized actual running data from the target phone/belt setup.

## Public research-data validation

The public-data plan, provenance, limitations and ready-to-run commands are in [PUBLIC_DATASETS.md](PUBLIC_DATASETS.md). The production Dart `GaitEngine` can replay pinned running and sitting smartphone trials, and an independent time-aligned event scorer is provided for OptoJump/force-plate data. Public-data benchmark runs have **not** been executed in this packaging environment because the Dart/Flutter SDK and direct external downloads are unavailable. Activity-only labels do **not** measure step accuracy.

## Research references

- Flutter source comparison: [Running Dynamics](https://github.com/dadcolin/running_dynamics)
- Methods and publicly described running IMU validation: [Running_IMU](https://github.com/MyriamLubrano/Running_IMU)
- Validation methodology: [gaitmap](https://github.com/mad-lab-fau/gaitmap)
- Off-the-shelf signal logger: [phyphox](https://phyphox.org/)
- Flutter sensor API: [sensors_plus](https://pub.dev/packages/sensors_plus)

The algorithm in this repo is experimental/original; it is not represented as an independently validated translation of published research.

## Codex handoff

- Repository-level rules: [AGENTS.md](AGENTS.md)
- Local Mac + Cloud provisioning and physical devices: [docs/CODEX_SETUP.md](docs/CODEX_SETUP.md)
- Research decisions and engineering milestones: [docs/ROADMAP.md](docs/ROADMAP.md)
- Live CI: https://github.com/sweslo17/GaitLab/actions

This repo is the canonical project, not the older ZIP bundles. Cloud tasks may run without releasing an APK/IPA. To use the latest local branch in a cloud task, push **that branch** when ready; do not merge into `main` or publish a mobile store release by default.
