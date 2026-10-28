#!/usr/bin/env bash
# Generate native runners without allowing 'flutter create' to modify tracked app code.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter SDK not found. Install Flutter 3.47.7+ (or use scripts/codex_cloud_setup.sh)." >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "Python 3 is needed for iOS settings and offline validation." >&2
  exit 2
fi

platforms=()
if [[ ! -d android ]]; then platforms+=(android); fi
if [[ "$(uname -s)" == "Darwin" && ! -d ios ]]; then platforms+=(ios); fi

if (( ${#platforms[@]} > 0 )); then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  joined="$(IFS=,; echo "${platforms[*]}")"
  flutter create --no-pub --project-name gaitlab --org dev.gaitlab \
    --platforms="$joined" "$tmp/gaitlab"
  for platform in "${platforms[@]}"; do
    if [[ ! -d "$tmp/gaitlab/$platform" ]]; then
      echo "Missing generated $platform runner; refusing to continue." >&2
      exit 1
    fi
    cp -R "$tmp/gaitlab/$platform" "./$platform"
  done
fi

# iOS runner needs a meaningful motion permission explanation and iOS 15 baseline.
if [[ -f ios/Runner/Info.plist ]]; then
  python3 - <<'PYIOS'
from pathlib import Path
import plistlib
import re
plist = Path("ios/Runner/Info.plist")
with plist.open("rb") as f:
    data = plistlib.load(f)
if not data.get("NSMotionUsageDescription"):
    data["NSMotionUsageDescription"] = (
        "GaitLab needs motion sensors to estimate running cadence and gait variability."
    )
    plist.write_bytes(plistlib.dumps(data))
project = Path("ios/Runner.xcodeproj/project.pbxproj")
if project.exists():
    original = project.read_text()
    updated = re.sub(r"IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;",
                     "IPHONEOS_DEPLOYMENT_TARGET = 15.0;", original)
    if updated != original:
        project.write_text(updated)
podfile = Path("ios/Podfile")
if podfile.exists():
    original = podfile.read_text()
    replacement = "platform :ios, '15.0'"
    if re.search(r"^\s*#?\s*platform\s+:ios,", original, re.M):
        updated = re.sub(r"^\s*#?\s*platform\s+:ios,.*$",
                         replacement, original, count=1, flags=re.M)
    else:
        updated = replacement + "\n" + original
    if updated != original:
        podfile.write_text(updated)
PYIOS
fi
flutter pub get
echo "Ready: run 'bash scripts/verify_local.sh' or 'flutter run -d DEVICE_ID'."
