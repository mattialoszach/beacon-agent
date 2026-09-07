#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."
beacon_build_arguments=(-c release)
if [[ "${BEACON_BUILD_UNIVERSAL:-0}" == "1" ]]; then
    beacon_build_arguments+=(--arch arm64 --arch x86_64)
fi
swift build "${beacon_build_arguments[@]}"
beacon_binary_directory=$(swift build "${beacon_build_arguments[@]}" --show-bin-path)

rm -rf .build/Beacon.app
mkdir -p .build/Beacon.app/Contents/MacOS
mkdir -p .build/Beacon.app/Contents/Resources
cp Beacon/Resources/Info.plist .build/Beacon.app/Contents/Info.plist
cp "${beacon_binary_directory}/Beacon" .build/Beacon.app/Contents/MacOS/Beacon
cp Beacon/Resources/AppIcon.icns .build/Beacon.app/Contents/Resources/AppIcon.icns
cp Beacon/Resources/Images/AppIcon.png .build/Beacon.app/Contents/Resources/AppIcon.png
cp Beacon/Resources/Images/BeaconLogo.png .build/Beacon.app/Contents/Resources/BeaconLogo.png
# Ship the SwiftPM resource bundle too, so resource lookup never depends on a build path.
if [[ -d "${beacon_binary_directory}/Beacon_Beacon.bundle" ]]; then
    cp -R "${beacon_binary_directory}/Beacon_Beacon.bundle" \
        .build/Beacon.app/Contents/Resources/Beacon_Beacon.bundle
fi
beacon_signing_identity="${BEACON_SIGNING_IDENTITY:--}"
if [[ "$beacon_signing_identity" == "-" ]]; then
    # An ad-hoc signature is identified only by its cdhash, which changes on every build.
    # macOS therefore treats each rebuild as a different app: Accessibility and Screen
    # Recording grants and the Keychain ACL must be given again. Set
    # BEACON_SIGNING_IDENTITY to a stable identity to keep them across builds.
    codesign --force --sign - --identifier org.beacon.agent .build/Beacon.app
    print -- "Ad-hoc signed. Re-grant Accessibility/Screen Recording after each rebuild."
else
    codesign --force --options runtime --timestamp \
        --identifier org.beacon.agent --sign "$beacon_signing_identity" .build/Beacon.app
fi
codesign --verify --deep --strict .build/Beacon.app

echo "Built ${PWD}/.build/Beacon.app"
