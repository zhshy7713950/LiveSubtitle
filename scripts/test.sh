#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -lt 1 || -z "$1" ]]; then
  printf 'Usage: %s <iOS-27+-simulator-UDID> [xcodebuild test options]\n' "$0" >&2
  exit 2
fi
simulator_udid="$1"
shift
xcodebuild -project LiveSubtitle.xcodeproj -scheme LiveSubtitle \
  -configuration Debug -destination "platform=iOS Simulator,id=${simulator_udid}" \
  -derivedDataPath build/tests CODE_SIGNING_ALLOWED=NO test "$@"
