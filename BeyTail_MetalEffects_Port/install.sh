#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(pwd)}"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$ROOT/beyblade/BeyTail"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_ROOT="$ROOT/tmp/metal_effect_backup_$STAMP"
PIC_CORE_REL="UI/pic/icon/PicTrailMetalRenderCore.swift"

if [[ ! -d "$ROOT/beyblade.xcodeproj" || ! -d "$APP_ROOT/UI" ]]; then
  echo "[ERROR] Project root must contain beyblade.xcodeproj and beyblade/BeyTail/UI"
  echo "Usage: ./install.sh /path/to/beyblade-project-root"
  exit 1
fi

mkdir -p \
  "$BACKUP_ROOT/UI" \
  "$BACKUP_ROOT/Effects" \
  "$BACKUP_ROOT/UI/pic/icon"

if [[ -d "$APP_ROOT/UI/MetalEffects" ]]; then
  mv "$APP_ROOT/UI/MetalEffects" "$BACKUP_ROOT/UI/MetalEffects"
fi

# Move the deprecated OpenGL ES implementation out of the synchronized Xcode
# source root so it cannot remain in Compile Sources.
if [[ -d "$APP_ROOT/UI/GLEffects" ]]; then
  mv "$APP_ROOT/UI/GLEffects" "$BACKUP_ROOT/UI/GLEffects"
fi

if [[ -f "$APP_ROOT/Effects/TrailOverlayView.swift" ]]; then
  cp "$APP_ROOT/Effects/TrailOverlayView.swift" \
     "$BACKUP_ROOT/Effects/TrailOverlayView.swift"
fi

# Recording and offline-video rendering already enter through this adapter.
# Replacing it makes all three render paths use the same MetalEffect classes.
if [[ -f "$APP_ROOT/$PIC_CORE_REL" ]]; then
  cp "$APP_ROOT/$PIC_CORE_REL" \
     "$BACKUP_ROOT/$PIC_CORE_REL"
fi

cp -R "$SOURCE_DIR/beyblade/BeyTail/UI/MetalEffects" \
      "$APP_ROOT/UI/MetalEffects"

cp "$SOURCE_DIR/beyblade/BeyTail/Effects/TrailOverlayView.swift" \
   "$APP_ROOT/Effects/TrailOverlayView.swift"

cp "$SOURCE_DIR/beyblade/BeyTail/$PIC_CORE_REL" \
   "$APP_ROOT/$PIC_CORE_REL"

echo "[OK] Metal effects installed"
echo "[OK] Live preview alias replaced"
echo "[OK] Recording/offline Metal adapter replaced"
echo "[OK] Backup: $BACKUP_ROOT"
echo

echo "The project uses a PBXFileSystemSynchronizedRootGroup, so files under"
echo "beyblade/ are normally discovered automatically by Xcode."
echo
echo "Next:"
echo "  \"$SOURCE_DIR/validate.sh\" \"$ROOT\""
echo "  open \"$ROOT/beyblade.xcodeproj\""
echo "  Product > Clean Build Folder"
echo "  Build on a physical iPhone"
