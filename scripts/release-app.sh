#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."

beacon_fail() { print -u2 -- "$*"; exit 1; }

beacon_check_identity() {
    [[ -n "${BEACON_SIGNING_IDENTITY:-}" && "$BEACON_SIGNING_IDENTITY" != "-" ]] \
        || beacon_fail "Set BEACON_SIGNING_IDENTITY to your Developer ID Application identity."
    security find-identity -v -p codesigning | /usr/bin/grep -F -- "$BEACON_SIGNING_IDENTITY" \
        | /usr/bin/grep -q '"Developer ID Application:' \
        || beacon_fail "The selected Developer ID Application identity is not installed or valid."
}

beacon_verify_release() {
    codesign --verify --deep --strict "$1"
    local beacon_signature
    beacon_signature=$(codesign --display --verbose=4 "$1" 2>&1)
    print -r -- "$beacon_signature" | /usr/bin/grep -q '^Authority=Developer ID Application:' \
        || beacon_fail "This app needs a Developer ID Application signature."
    print -r -- "$beacon_signature" | /usr/bin/grep -q 'flags=.*runtime' \
        || beacon_fail "The app is missing hardened runtime."
    print -r -- "$beacon_signature" | /usr/bin/grep -q '^Timestamp=' \
        || beacon_fail "The signature is missing a secure timestamp."
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist")" == "org.beacon.agent" ]] \
        || beacon_fail "This is not the Beacon app bundle."
    lipo -verify_arch arm64 x86_64 "$1/Contents/MacOS/Beacon"
}

case "${1:-help}" in
    check)
        beacon_check_identity
        xcrun --find notarytool > /dev/null
        xcrun --find stapler > /dev/null
        print -- "Developer ID and notarization tools are available."
        ;;
    prepare)
        beacon_check_identity
        BEACON_BUILD_UNIVERSAL=1 ./scripts/build-app.sh
        beacon_verify_release "$PWD/.build/Beacon.app"
        print -- "Test .build/Beacon.app before running the notarize command."
        ;;
    notarize)
        [[ $# == 2 ]] || beacon_fail "Usage: $0 notarize /path/to/tested/Beacon.app"
        [[ -n "${BEACON_NOTARY_PROFILE:-}" ]] \
            || beacon_fail "Set BEACON_NOTARY_PROFILE to credentials stored by notarytool in Keychain."
        beacon_app="${2:A}"
        [[ -d "$beacon_app" ]] || beacon_fail "App bundle not found."
        beacon_verify_release "$beacon_app"
        mkdir -p .build/releases
        beacon_release_dir=$(mktemp -d "$PWD/.build/releases/Beacon.XXXXXX")
        # Work on a copy of the exact tested bundle. Notarization never rebuilds the app.
        ditto "$beacon_app" "$beacon_release_dir/Beacon.app"
        ditto -c -k --keepParent "$beacon_release_dir/Beacon.app" "$beacon_release_dir/submission.zip"
        xcrun notarytool submit "$beacon_release_dir/submission.zip" \
            --keychain-profile "$BEACON_NOTARY_PROFILE" --wait --timeout 30m \
            --output-format plist > "$beacon_release_dir/notarization.plist"
        beacon_notary_status=$(/usr/libexec/PlistBuddy -c 'Print :status' "$beacon_release_dir/notarization.plist")
        [[ "$beacon_notary_status" == "Accepted" ]] \
            || beacon_fail "Notarization was not accepted. Inspect $beacon_release_dir/notarization.plist and retrieve the submission log."
        xcrun stapler staple "$beacon_release_dir/Beacon.app"
        xcrun stapler validate "$beacon_release_dir/Beacon.app"
        beacon_verify_release "$beacon_release_dir/Beacon.app"
        spctl --assess --type execute --verbose=2 "$beacon_release_dir/Beacon.app"
        ditto -c -k --keepParent "$beacon_release_dir/Beacon.app" "$beacon_release_dir/Beacon.zip"
        shasum -a 256 "$beacon_release_dir/Beacon.zip" > "$beacon_release_dir/Beacon.zip.sha256"
        print -- "Notarized artifact: $beacon_release_dir/Beacon.zip"
        ;;
    *)
        print -- "Usage: $0 check | prepare | notarize /path/to/tested/Beacon.app"
        print -- "prepare requires BEACON_SIGNING_IDENTITY; notarize requires BEACON_NOTARY_PROFILE."
        [[ "${1:-help}" == "help" ]]
        ;;
esac
