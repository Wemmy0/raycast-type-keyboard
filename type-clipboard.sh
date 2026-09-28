#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Type Clipboard
# @raycast.mode silent

# Optional parameters:
# @raycast.icon ⌨️
# @raycast.packageName Text Utils

# Documentation:
# @raycast.description Types clipboard text with progress. Press any key to cancel.
# @raycast.author tom

set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"
HELPER="$SCRIPT_DIR/type-clipboard.swift"
BINARY="$SCRIPT_DIR/.type-clipboard-helper"

# Compile once, then rebuild only when the helper changes.
if [[ ! -x "$BINARY" || "$HELPER" -nt "$BINARY" ]]; then
    /usr/bin/xcrun swiftc "$HELPER" -o "$BINARY"
fi

exec "$BINARY"
