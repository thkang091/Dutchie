#!/bin/bash

# This script checks if the project is iOS
# Add this as a "Run Script Phase" in Build Phases

if [ "$PLATFORM_NAME" != "iphoneos" ] && [ "$PLATFORM_NAME" != "iphonesimulator" ]; then
    echo "error: ⚠️ WRONG PROJECT TYPE ⚠️"
    echo "error: This is an iOS-only app. You created a $PLATFORM_NAME project."
    echo "error: Please create a new iOS App project and try again."
    echo "error: See TROUBLESHOOTING.md for detailed instructions."
    exit 1
fi

echo "✅ Correct platform: $PLATFORM_NAME"
