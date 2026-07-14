#!/bin/sh
# Archives Hyperfocal and uploads it to App Store Connect (for TestFlight /
# Mac App Store), via the Xcode project (App/Hyperfocal.xcodeproj — generated
# by XcodeGen). Signing is automatic: Xcode creates the Apple Distribution
# certificate and Mac App Store provisioning profile on first run
# (-allowProvisioningUpdates), using the account session from
# Xcode → Settings → Accounts. The App Store Connect app record (bundle ID
# com.ethannicholas.hyperfocal) must exist before an upload can land.
#
#   Scripts/upload-mas.sh [options]
#
#   --no-upload            export the signed .pkg into dist/mas/ instead of
#                          uploading (dry run of everything but the upload)
#
#   VERSION=x.y.z          override the marketing version (default: latest git
#                          tag, else 0.1.0)
#
# The build number is the commit count, so commit before re-uploading — App
# Store Connect rejects a reused CFBundleVersion. For headless use (CI),
# add -authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID
# (an App Store Connect API key) to both xcodebuild invocations.
set -e
cd "$(dirname "$0")/.."

UPLOAD=1
while [ $# -gt 0 ]; do
    case "$1" in
        --no-upload) UPLOAD=0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo 1.0.0)}"
VERSION="${VERSION#v}"  # tags are v1.0.0; CFBundleShortVersionString must be bare integers
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)
TEAM_ID=$(sed -n 's/.*DEVELOPMENT_TEAM: *//p' App/project.yml)

if [ ! -d App/Hyperfocal.xcodeproj ] || [ ! -f App/Hyperfocal.entitlements ]; then
    (cd App && xcodegen generate)
fi

ARCHIVE=.build/xcode/Hyperfocal.xcarchive
echo "== archiving Hyperfocal $VERSION ($BUILD_NUMBER) for team $TEAM_ID"
xcodebuild -project App/Hyperfocal.xcodeproj -scheme Hyperfocal \
    -configuration Release -derivedDataPath .build/xcode \
    -archivePath "$ARCHIVE" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    -allowProvisioningUpdates archive \
    | grep -E "^\*\* ARCHIVE" || { echo "archive failed" >&2; exit 1; }

# manageAppVersionAndBuildNumber defaults to true, which would let Xcode
# renumber the build behind the git-derived numbering above.
EXPORT_OPTS=$(mktemp -t exportoptions).plist
if [ "$UPLOAD" = 1 ]; then DEST=upload; else DEST=export; fi
cat > "$EXPORT_OPTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>$DEST</string>
	<key>teamID</key><string>$TEAM_ID</string>
	<key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF

echo "== exporting ($DEST)"
if [ "$UPLOAD" = 1 ]; then
    xcodebuild -exportArchive -archivePath "$ARCHIVE" \
        -exportOptionsPlist "$EXPORT_OPTS" -allowProvisioningUpdates
    echo "uploaded Hyperfocal $VERSION ($BUILD_NUMBER) — check App Store" \
        "Connect → TestFlight once processing finishes"
else
    rm -rf dist/mas
    xcodebuild -exportArchive -archivePath "$ARCHIVE" \
        -exportOptionsPlist "$EXPORT_OPTS" -allowProvisioningUpdates \
        -exportPath dist/mas
    echo "== artifacts:"
    ls -la dist/mas/
fi
