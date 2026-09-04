#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."
swift build -c release

rm -rf .build/Beacon.app
mkdir -p .build/Beacon.app/Contents/MacOS
mkdir -p .build/Beacon.app/Contents/Resources
cp Beacon/Resources/Info.plist .build/Beacon.app/Contents/Info.plist
cp .build/release/Beacon .build/Beacon.app/Contents/MacOS/Beacon
cp Beacon/Resources/AppIcon.icns .build/Beacon.app/Contents/Resources/AppIcon.icns
cp Beacon/Resources/Images/AppIcon.png .build/Beacon.app/Contents/Resources/AppIcon.png
cp Beacon/Resources/Images/BeaconLogo.png .build/Beacon.app/Contents/Resources/BeaconLogo.png
codesign --force --deep --sign - .build/Beacon.app

echo "Built ${PWD}/.build/Beacon.app"
