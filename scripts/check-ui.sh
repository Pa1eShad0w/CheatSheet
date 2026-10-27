#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

support=.build/overlay-preview-support
mkdir -p "$support"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  -parse-as-library -emit-module -emit-library -static -module-name CheatSheetCore \
  Sources/CheatSheetCore/*.swift \
  -emit-module-path "$support/CheatSheetCore.swiftmodule" -o "$support/libCheatSheetCore.a"

xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  -I "$support" -L "$support" -lCheatSheetCore \
  Sources/CheatSheetApp/MenuReadSession.swift scripts/menu-session-check.swift -o .build/menu-session-check
.build/menu-session-check

xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  -I "$support" -L "$support" -lCheatSheetCore \
  Sources/CheatSheetApp/ShortcutColumns.swift Sources/CheatSheetApp/OverlayView.swift \
  Sources/CheatSheetApp/OverlayController.swift scripts/render-overlay.swift -o .build/render-overlay
.build/render-overlay
.build/render-overlay --dark
.build/render-overlay --compact
