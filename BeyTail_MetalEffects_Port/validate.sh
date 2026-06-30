#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(pwd)}"
APP_ROOT="$ROOT/beyblade/BeyTail"
METAL_ROOT="$APP_ROOT/UI/MetalEffects"
PIC_CORE="$APP_ROOT/UI/pic/icon/PicTrailMetalRenderCore.swift"
ALIAS_FILE="$APP_ROOT/Effects/TrailOverlayView.swift"

if [[ ! -d "$METAL_ROOT" ]]; then
  echo "[ERROR] Missing $METAL_ROOT"
  exit 1
fi

if [[ ! -f "$METAL_ROOT/Shaders/BeyTailEffects.metal" ]]; then
  echo "[ERROR] Missing BeyTailEffects.metal"
  exit 1
fi

if [[ ! -f "$PIC_CORE" ]]; then
  echo "[ERROR] Missing recording/offline adapter: $PIC_CORE"
  exit 1
fi

if [[ ! -f "$ALIAS_FILE" ]] || ! grep -q 'MetalTrailOverlayView' "$ALIAS_FILE"; then
  echo "[ERROR] TrailOverlayView is not mapped to MetalTrailOverlayView"
  exit 1
fi

if grep -R -nE 'import (OpenGLES|GLKit)|GLKView|EAGLContext|glUseProgram|glDrawArrays' "$METAL_ROOT"; then
  echo "[ERROR] Deprecated OpenGL symbols remain in UI/MetalEffects"
  exit 1
fi

if [[ -d "$APP_ROOT/UI/GLEffects" ]]; then
  echo "[ERROR] UI/GLEffects still exists inside the synchronized source root"
  echo "        Move it to tmp/ or remove it from the target."
  exit 1
fi

EFFECT_COUNT=$(find "$METAL_ROOT/Effects" -name '*MetalEffect.swift' | wc -l | tr -d ' ')
if [[ "$EFFECT_COUNT" != "10" ]]; then
  echo "[ERROR] Expected 10 Metal effect classes, found $EFFECT_COUNT"
  exit 1
fi

PROGRAM_COUNT=$(grep -c 'case ' "$METAL_ROOT/Core/MetalProgram.swift" || true)
SHADER_BRANCH_COUNT=$(grep -cE 'shader == [0-9]+u' "$METAL_ROOT/Shaders/BeyTailEffects.metal" || true)
if [[ "$SHADER_BRANCH_COUNT" -lt 21 ]]; then
  echo "[ERROR] Expected at least 21 MSL shader branches, found $SHADER_BRANCH_COUNT"
  exit 1
fi

if command -v swiftc >/dev/null 2>&1; then
  while IFS= read -r -d '' file; do
    swiftc -frontend -parse "$file" >/dev/null
  done < <(
    printf '%s\0' "$ALIAS_FILE" "$PIC_CORE"
    find "$METAL_ROOT" -name '*.swift' -print0
  )
  echo "[OK] Swift syntax parse"
fi

if command -v xcrun >/dev/null 2>&1; then
  SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
  xcrun -sdk iphoneos metal \
    -std=ios-metal2.4 \
    -isysroot "$SDK_PATH" \
    -c "$METAL_ROOT/Shaders/BeyTailEffects.metal" \
    -o /tmp/BeyTailEffects.air
  rm -f /tmp/BeyTailEffects.air
  echo "[OK] Metal shader compile"
else
  echo "[WARN] xcrun not found; Metal shader compilation skipped"
fi

echo "[OK] Metal classes: $EFFECT_COUNT"
echo "[OK] MSL shader branches: $SHADER_BRANCH_COUNT"
echo "[OK] Recording/offline adapter installed"
echo "[OK] Metal effect package validation completed"
