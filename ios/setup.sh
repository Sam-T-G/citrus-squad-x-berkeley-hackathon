#!/usr/bin/env bash
# One-time setup for the CitrusSquad iOS app. Run from anywhere:
#   ./ios/setup.sh
# It installs XcodeGen if needed, creates your local signing config, and generates the project.
set -euo pipefail
cd "$(dirname "$0")"

# 1. XcodeGen
if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "Installing XcodeGen via Homebrew…"
    brew install xcodegen
  else
    echo "XcodeGen is not installed and Homebrew was not found."
    echo "Install Homebrew from https://brew.sh then re-run, or install XcodeGen another way."
    exit 1
  fi
fi

# 2. Per-developer signing config
if [ ! -f Local.xcconfig ]; then
  cp Local.xcconfig.example Local.xcconfig
  echo ""
  echo "Created ios/Local.xcconfig from the template."
  echo ">> Open ios/Local.xcconfig and set DEVELOPMENT_TEAM and APP_BUNDLE_ID before building."
  echo "   (You can also leave DEVELOPMENT_TEAM blank and pick your team in Xcode.)"
  echo ""
fi

# 3. Generate the Xcode project
xcodegen generate

echo ""
echo "Done. Next:"
echo "  open ios/CitrusSquad.xcodeproj"
echo "  pick your iPhone as the run destination, then press Cmd-R."
