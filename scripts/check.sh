#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build
mkdir -p .build
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  Sources/CheatSheetCore/*.swift scripts/core-check.swift -o .build/core-check
.build/core-check
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  Sources/CheatSheetCore/*.swift scripts/menu-attribute-check.swift -o .build/menu-attribute-check
.build/menu-attribute-check
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  Sources/CheatSheetCore/*.swift scripts/menu-recovery-check.swift -o .build/menu-recovery-check
.build/menu-recovery-check

if [[ "${1:-}" == "--xctest" ]]; then
  swift test
elif [[ -n "${1:-}" ]]; then
  echo "Usage: bash scripts/check.sh [--xctest]" >&2
  exit 2
fi
