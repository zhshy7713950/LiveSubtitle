#!/bin/bash
# Framework/build validation only. This does not run behavioral or device tests.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check_docs.py
plutil -lint Config/Info.plist LiveSubtitle.xcodeproj/project.pbxproj
mkdir -p build/logs
run_build() {
  local build_label="$1"
  shift
  if xcodebuild -project LiveSubtitle.xcodeproj -scheme LiveSubtitle \
    CODE_SIGNING_ALLOWED=NO "$@" > "build/logs/${build_label}.log" 2>&1; then
    printf '%s: build succeeded\n' "$build_label"
  else
    tail -n 70 "build/logs/${build_label}.log"
    return 1
  fi
}
run_build device-debug -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build/device-debug build
run_build device-release -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/device-release build
run_build simulator-tests -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/simulator build-for-testing
printf 'Framework validation complete; behavioral tests and G0 were not run.\n'
