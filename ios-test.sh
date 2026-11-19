#!/usr/bin/env bash
# Gala Engine gate: TeaThreeKit unit and recorded-contract tests.
set -euo pipefail

: "${GALA_BUILD_DIR:?Gala build directory is required}"
cd Packages/TeaThreeKit
swift test --scratch-path "$GALA_BUILD_DIR/KitTests"
