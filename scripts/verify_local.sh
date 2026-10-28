#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash -n scripts/bootstrap.sh
python3 -m py_compile tools/*.py
python3 -m unittest discover -s tools -p 'test_*.py' -v
if [[ "${1:-}" == '--python-only' ]]; then
  echo 'SKIPPED: Flutter analyzer, Flutter tests, Android/iOS builds (python-only requested).'
  exit 0
fi
if ! command -v flutter >/dev/null 2>&1; then
  echo 'INCOMPLETE: Flutter SDK unavailable; cannot mark Flutter verification as passed.' >&2
  exit 2
fi
if [[ ! -d android || ! -d ios ]]; then
  bash scripts/bootstrap.sh
fi
flutter analyze
flutter test
printf '\nPASS: local static analysis and tests. Run platform builds separately.\n'
