#!/usr/bin/env bash
# Gala Engine recipe: build an unsigned Release device IPA (Gala signs it).
#
# If a T3 credential exists at $TEA_THREE_BOOTSTRAP (default
# ~/.config/tea-three/bootstrap.json, made with `tea-three pair`), it's copied
# into the app so the build arrives already paired. It never enters the repo.
# The natural voice model is embedded the same way (scripts/fetch-voices.sh).
set -euo pipefail

: "${GALA_BUILD_DIR:?Gala build directory is required}"
: "${GALA_ARTIFACT_DIR:?Gala artifact directory is required}"

xcodegen generate --quiet

DERIVED_DATA="$GALA_BUILD_DIR/DerivedData"
xcodebuild -quiet \
  -project TeaThree.xcodeproj -scheme TeaThree \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" -packageCachePath "$GALA_BUILD_DIR/SwiftPM" \
  CODE_SIGNING_ALLOWED=NO build

APP="$DERIVED_DATA/Build/Products/Release-iphoneos/TeaThree.app"
test -d "$APP"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/teathree-gala.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload" "$GALA_ARTIFACT_DIR"
ditto "$APP" "$STAGE/Payload/TeaThree.app"

BOOTSTRAP="${TEA_THREE_BOOTSTRAP:-$HOME/.config/tea-three/bootstrap.json}"
if [[ -f "$BOOTSTRAP" ]]; then
  cp "$BOOTSTRAP" "$STAGE/Payload/TeaThree.app/TeaThreeBootstrap.json"
  echo "Bundled T3 credential from $BOOTSTRAP"
fi

# Natural voices (Kyutai Pocket TTS, ~180 MB), downloaded once into a cache
# and verified. TEA_THREE_SKIP_VOICES=1 builds with iPhone voices only.
if [[ "${TEA_THREE_SKIP_VOICES:-}" != "1" ]]; then
  VOICES="$(scripts/fetch-voices.sh)"
  mkdir -p "$STAGE/Payload/TeaThree.app/Pocket"
  cp -R "$VOICES/FlowLM.mlmodelc" "$VOICES/Mimi.mlmodelc" "$VOICES/voices" "$STAGE/Payload/TeaThree.app/Pocket/"
  echo "Embedded natural voices from $VOICES"
fi

IPA="$GALA_ARTIFACT_DIR/TeaThree.ipa"
(cd "$STAGE" && zip -qry "$IPA" Payload)
shasum -a 256 "$IPA"
