#!/bin/bash
set -euo pipefail

# AgentBar DMG Builder
# Creates a drag-and-drop DMG installer for macOS
#
# Usage:
#   ./scripts/create-dmg.sh              # Build + create DMG
#   ./scripts/create-dmg.sh --skip-build # DMG only (uses existing build)

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
SCHEME="AgentBar"
APP_NAME="AgentBar"
DMG_NAME="AgentBar.dmg"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
STAGING_DIR="$BUILD_DIR/dmg_staging"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"

SKIP_BUILD=false
if [[ "${1:-}" == "--skip-build" ]]; then
    SKIP_BUILD=true
fi

# ── Build & Archive ──────────────────────────────────────────────

if [[ "$SKIP_BUILD" == false ]]; then
    echo "==> Generating Xcode project..."
    if command -v xcodegen &>/dev/null; then
        cd "$PROJECT_DIR" && xcodegen generate
    else
        echo "    (xcodegen not found, using existing .xcodeproj)"
    fi

    echo "==> Archiving..."
    xcodebuild archive \
        -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
        -scheme "$SCHEME" \
        -archivePath "$ARCHIVE_PATH" \
        -configuration Release \
        SKIP_INSTALL=NO \
        BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
        | tail -5

    echo "==> Exporting..."
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        -exportPath "$EXPORT_PATH" \
        | tail -5
fi

APP_PATH="$EXPORT_PATH/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "Error: $APP_PATH not found. Run without --skip-build first."
    exit 1
fi

# ── Create DMG ───────────────────────────────────────────────────

echo "==> Creating DMG..."

# Clean previous staging
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Copy app
cp -R "$APP_PATH" "$STAGING_DIR/"

# Create Applications symlink (for drag-and-drop install)
ln -s /Applications "$STAGING_DIR/Applications"

# Remove old DMG if exists
rm -f "$DMG_PATH"

# Try create-dmg (brew install create-dmg) for a polished DMG
if command -v create-dmg &>/dev/null; then
    create-dmg \
        --volname "$APP_NAME" \
        --volicon "$APP_PATH/Contents/Resources/AppIcon.icns" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 128 \
        --icon "$APP_NAME.app" 150 185 \
        --icon "Applications" 450 185 \
        --hide-extension "$APP_NAME.app" \
        --app-drop-link 450 185 \
        --no-internet-enable \
        "$DMG_PATH" \
        "$STAGING_DIR"
else
    # Fallback: basic hdiutil DMG
    echo "    (install 'create-dmg' for a polished DMG: brew install create-dmg)"

    hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$STAGING_DIR" \
        -ov \
        -format UDZO \
        "$DMG_PATH"
fi

# Clean up staging
rm -rf "$STAGING_DIR"

DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1 | xargs)
echo ""
echo "==> Done! DMG created at:"
echo "    $DMG_PATH ($DMG_SIZE)"
