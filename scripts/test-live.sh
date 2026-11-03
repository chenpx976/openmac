#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_binary="$(mktemp -t openmac-live-checks)"
trap 'rm -f "$check_binary"' EXIT
xcrun swiftc Sources/openmac/OpenMacCore.swift Sources/openmac/OpenMacServer_macOS.swift \
  Sources/openmac/LivePipeline.swift Sources/openmac/LiveMultipart.swift Sources/openmac/SpeechTranscriber.swift \
  Sources/openmac/LiveSettingsView.swift Tests/LivePipelineChecks.swift -o "$check_binary"
"$check_binary"
