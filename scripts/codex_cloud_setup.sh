#!/usr/bin/env bash
# Optional Codex Cloud install script. Run in the cloud environment setup stage.
# Uses user-writable paths and a pinned stable Flutter SDK; never installs globally.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This helper is for Codex Cloud Linux. On macOS, install Flutter/Xcode normally." >&2
  exit 2
fi
if ! command -v git >/dev/null 2>&1; then
  echo "git is required to install Flutter." >&2; exit 2
fi
FLUTTER_VERSION="3.47.7"
flutter_root="${HOME}/.cache/gaitlab/flutter-${FLUTTER_VERSION}"
mkdir -p "${HOME}/.cache/gaitlab" "${HOME}/.local/bin"
if [[ ! -x "$flutter_root/bin/flutter" ]]; then
  git clone --depth 1 --branch "$FLUTTER_VERSION" \
    https://github.com/flutter/flutter.git "$flutter_root"
fi
ln -sfn "$flutter_root/bin/flutter" "${HOME}/.local/bin/flutter"
ln -sfn "$flutter_root/bin/dart" "${HOME}/.local/bin/dart"
export PATH="${HOME}/.local/bin:$PATH"
# Setup scripts and Codex tasks use different shells; make the user path persistent.
if ! grep -Fq '# GaitLab Codex Flutter PATH' "${HOME}/.bashrc" 2>/dev/null; then
  printf '\n# GaitLab Codex Flutter PATH\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "${HOME}/.bashrc"
fi
flutter --version
flutter config --no-analytics
bash scripts/bootstrap.sh
bash scripts/verify_local.sh
echo "Cloud checks completed. iOS native builds and physical sensor checks require a Mac + device."
