#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

bash -n scripts/bootstrap.sh scripts/verify_local.sh scripts/codex_cloud_setup.sh
python3 -m py_compile tools/*.py
python3 -m unittest discover -s tools -p 'test_*.py' -v

if [[ "${1:-}" == "--python-only" ]]; then
  echo "SKIPPED by request: Flutter analysis, Dart tests and platform builds."
  exit 0
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "UNVERIFIED: Flutter not installed; install it before accepting this build." >&2
  exit 2
fi

bash scripts/bootstrap.sh
flutter analyze
flutter test
echo "PASS: Python unit tests, flutter analyze, flutter test."
echo "NOT CHECKED HERE: APK/iOS build, device telemetry, ground-truth accuracy."
