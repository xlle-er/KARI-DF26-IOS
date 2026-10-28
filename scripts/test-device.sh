#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
: "${KARI_TEST_DEVICE_ID:?Set KARI_TEST_DEVICE_ID to your paired iPhone identifier}"
python3 scripts/configure-device-tests.py
stamp=$(date +%Y%m%d-%H%M%S)
mkdir -p build/device-results
xcodebuild -project KARI.xcodeproj -scheme KARI -configuration Debug \
  -destination "platform=iOS,id=${KARI_TEST_DEVICE_ID}" \
  -derivedDataPath build/device-derived \
  -allowProvisioningUpdates -parallel-testing-enabled NO \
  -skip-testing:KariUnitTests/DeviceRuntimeTests/testConfiguredLiveConnectionOnPhone \
  -skip-testing:KariUnitTests/DeviceRuntimeTests/testConfiguredLiveCompleteSpeechOnPhone \
  -skip-testing:KariUnitTests/DeviceRuntimeTests/testConfiguredLiveDuplexSpeechOnPhone \
  -skip-testing:KariUnitTests/DeviceRuntimeTests/testConfiguredLiveSpokenTurnOnPhone \
  -skip-testing:KariUnitTests/DeviceRuntimeTests/testWakeSharedCaptureLiveHandoff \
  -resultBundlePath "build/device-results/${stamp}.xcresult" test "$@"
