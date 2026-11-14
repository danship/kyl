#!/bin/sh
# Builds and runs KYL's tests: the app's pure source files, compiled together
# with tests/ into one program. The app itself never starts.
#
#   ./scripts/test.sh
#
# The files listed below are the ones the tests reach; a new pure file the
# tests need goes in this list. The flags match the app target's Swift
# settings in the Xcode project.
set -e
cd "$(dirname "$0")/.."

OUT=.test-build
mkdir -p "$OUT"

xcrun swiftc -swift-version 5 \
  -default-isolation MainActor \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -enable-upcoming-feature InferIsolatedConformances \
  -enable-upcoming-feature MemberImportVisibility \
  -o "$OUT/tests" \
  ClaudeUsage/Models.swift \
  ClaudeUsage/UsageParser.swift \
  ClaudeUsage/UsageForecaster.swift \
  ClaudeUsage/MenuBarTitle.swift \
  ClaudeUsage/MenuBarRings.swift \
  ClaudeUsage/NetworkGate.swift \
  ClaudeUsage/ProgressRingIcon.swift \
  ClaudeUsage/StatusChecker.swift \
  tests/*.swift

"$OUT/tests"
