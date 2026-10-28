#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v flutter >/dev/null 2>&1; then
  echo 'Flutter not found. Install Flutter 3.47.7+ and run flutter doctor first.' >&2
  exit 1
fi
# Generate standard Android/iOS runner projects. Safeguard all source files.
backup="$(mktemp -d)"
trap 'rm -rf "$backup"' EXIT
cp pubspec.yaml "$backup/pubspec.yaml"
cp -R lib "$backup/lib"
cp -R test "$backup/test"
flutter create --platforms=android,ios --org dev.gaitlab --project-name gaitlab .
cp "$backup/pubspec.yaml" pubspec.yaml
rm -rf lib test
cp -R "$backup/lib" lib
cp -R "$backup/test" test
# Required by sensors_plus for iOS motion data access.
if [[ -f ios/Runner/Info.plist ]]; then
  if ! grep -q NSMotionUsageDescription ios/Runner/Info.plist; then
    if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
      /usr/libexec/PlistBuddy -c 'Add :NSMotionUsageDescription string GaitLab 需要存取動作感測器以分析跑步步頻與晃動。' ios/Runner/Info.plist
    else
      # Flutter iOS scaffold uses XML plist; add key above final dict close.
      sed -i.bak '/<\/dict>/i\
\t<key>NSMotionUsageDescription</key>\
\t<string>GaitLab needs motion sensors to analyze running gait.</string>\
' ios/Runner/Info.plist
      rm -f ios/Runner/Info.plist.bak
    fi
  fi
fi
# Flutter 3.47 supports iOS 15+; keep the generated runner aligned with
# current simulator requirements, regardless of the template's old default.
if [[ -f ios/Runner.xcodeproj/project.pbxproj ]]; then
  python3 - <<'PYIOS'
from pathlib import Path
import re
p = Path('ios/Runner.xcodeproj/project.pbxproj')
s = p.read_text()
s = re.sub(r'IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;',
           'IPHONEOS_DEPLOYMENT_TARGET = 15.0;', s)
p.write_text(s)
p = Path('ios/Podfile')
if p.exists():
    s = p.read_text()
    if re.search(r"^\s*#?\s*platform\s+:ios,", s, flags=re.M):
        s = re.sub(r"^\s*#?\s*platform\s+:ios,.*$",
                   "platform :ios, '15.0'", s, count=1, flags=re.M)
    else:
        s = "platform :ios, '15.0'\n" + s
    p.write_text(s)
PYIOS
fi
flutter pub get
printf '\nReady. Connect a physical device, then run: flutter run\n'
