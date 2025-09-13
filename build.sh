#!/bin/bash

# Build script for Voxport
# Kills running instances, builds with xcodebuild, and launches on success

set -e  # Exit on any error

# Kill any running instances
pkill -f "Voxport" > /dev/null 2>&1 || true
sleep 1

# Clean and build
LOG_FILE=$(mktemp)
trap 'rm -f "$LOG_FILE"' EXIT

if xcodebuild clean build -project Voxport.xcodeproj -scheme Voxport -configuration Debug > "$LOG_FILE" 2>&1; then
    # Build successful
    DERIVED_DATA_DIR="$HOME/Library/Developer/Xcode/DerivedData"
    APP_PATH=$(find "$DERIVED_DATA_DIR" -name "Voxport.app" -path "*/Build/Products/Debug/*" 2>/dev/null | grep -v Index.noindex | head -1)
    
    if [ -n "$APP_PATH" ] && [ -d "$APP_PATH" ]; then
        open "$APP_PATH"
        echo "✅ Voxport built and launched."
    else
        echo "❌ Build successful, but app not found in DerivedData."
        echo "Searched in: $DERIVED_DATA_DIR"
        exit 1
    fi
else
    echo "❌ Build failed!"
    cat "$LOG_FILE"
    exit 1
fi
