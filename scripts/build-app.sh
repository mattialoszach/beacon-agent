#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."
swift build -c release

rm -rf .build/Beacon.app
mkdir -p .build/Beacon.app/Contents/MacOS
mkdir -p .build/Beacon.app/Contents/Resources
cp Beacon/Resources/Info.plist .build/Beacon.app/Contents/Info.plist
cp .build/release/Beacon .build/Beacon.app/Contents/MacOS/Beacon
codesign --force --deep --sign - .build/Beacon.app

echo "Built ${PWD}/.build/Beacon.app"
