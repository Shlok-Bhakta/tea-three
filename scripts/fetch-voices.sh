#!/usr/bin/env bash
# Downloads the natural voice (Kyutai Pocket TTS, converted to Core ML for MB
# Books) once, verifies every file against scripts/pocket-tts.sha256, and
# unpacks it. Prints the ready directory: FlowLM.mlmodelc, Mimi.mlmodelc, voices/.
set -euo pipefail

RELEASE="pocket-tts-2026-09-v2"
BASE="https://github.com/Marginally-Better-Apps/mb-books/releases/download/$RELEASE"
HERE="$(cd "$(dirname "$0")" && pwd)"
CACHE="${TEA_THREE_VOICE_CACHE:-$HOME/.cache/tea-three/$RELEASE}"
mkdir -p "$CACHE/downloads" "$CACHE/voices"

grep -v '^#' "$HERE/pocket-tts.sha256" | while read -r name sum; do
  [[ -n "$name" ]] || continue
  file="$CACHE/downloads/$name"
  if [[ ! -f "$file" ]] || [[ "$(shasum -a 256 "$file" | cut -d' ' -f1)" != "$sum" ]]; then
    echo "Downloading $name" >&2
    curl -fsSL --retry 3 -o "$file.part" "$BASE/$name"
    [[ "$(shasum -a 256 "$file.part" | cut -d' ' -f1)" == "$sum" ]] || { echo "Checksum mismatch: $name" >&2; exit 1; }
    mv "$file.part" "$file"
  fi
  case "$name" in
    *.mlmodelc.aar)
      model="${name%.aar}"
      if [[ ! -d "$CACHE/$model" ]]; then
        rm -rf "$CACHE/staging" && mkdir -p "$CACHE/staging"
        aa extract -i "$file" -d "$CACHE/staging"
        found="$(find "$CACHE/staging" -maxdepth 2 -name "$model" -type d | head -1)"
        [[ -n "$found" ]] || { echo "No $model in $name" >&2; exit 1; }
        mv "$found" "$CACHE/$model"
        rm -rf "$CACHE/staging"
      fi
      ;;
    *.bin) cp -n "$file" "$CACHE/voices/$name" 2>/dev/null || true ;;
  esac
done
echo "$CACHE"
