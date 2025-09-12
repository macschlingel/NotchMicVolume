#!/bin/bash

# Build script for NotchMicVolume
# Kills running instances, builds with xcodebuild, and launches on success

set -e  # Exit on any error

echo "🔨 Building NotchMicVolume..."

# Kill any running instances
echo "🔄 Killing running instances..."
pkill -f "NotchMicVolume" || true
sleep 1

# Clean and build
echo "🏗️  Building project..."
xcodebuild clean build -project NotchMicVolume.xcodeproj -scheme NotchMicVolume -configuration Release

# Check if build was successful
if [ $? -eq 0 ]; then
    echo "✅ Build successful! Launching app..."
    
    # Find and launch the built app
    # Look for the app in the Xcode DerivedData directory
    DERIVED_DATA_DIR="$HOME/Library/Developer/Xcode/DerivedData"
    APP_PATH=$(find "$DERIVED_DATA_DIR" -name "NotchMicVolume.app" -path "*/Build/Products/Release/*" 2>/dev/null | head -1)
    
    if [ -n "$APP_PATH" ] && [ -d "$APP_PATH" ]; then
        open "$APP_PATH"
        echo "🚀 App launched from: $APP_PATH"
    else
        echo "❌ Built app not found in DerivedData"
        echo "Searched in: $DERIVED_DATA_DIR"
        exit 1
    fi
else
    echo "❌ Build failed!"
    exit 1
fi
