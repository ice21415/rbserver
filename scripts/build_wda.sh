#!/bin/zsh
# Builds + patches + ad-hoc-signs + renames the WebDriverAgent runner (as
# rbserver.app) for jailbroken SSH deploy.
# No Apple team/provisioning involved anywhere in this script -- CODE_SIGNING_ALLOWED=NO
# during build, then `ldid` ad-hoc-signs the result. Safe to re-run; wipes and rebuilds
# every time (fast enough, and avoids any stale-signature edge cases).
set -e

WDA_PROJ="$HOME/.appium/node_modules/appium-xcuitest-driver/node_modules/appium-webdriveragent"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build/wda"
# Xcode names build-for-testing output after the vendored WebDriverAgent
# project's own scheme/target names -- that project lives inside
# node_modules and isn't ours to rename. APP/XCTEST_BUNDLE below are renamed
# to rbserver.app / rbserver.xctest as the very last step once the build
# (and everything that reads these paths mid-build) is done.
XCODE_APP="$BUILD_DIR/Build/Products/Debug-iphoneos/WebDriverAgentRunner-Runner.app"
APP="$BUILD_DIR/Build/Products/Debug-iphoneos/rbserver.app"
BUNDLE_ID="com.rbserver.tests"
ENTITLEMENTS="$ROOT/build/entitlements.plist"

echo "[build] Removing previous build dir..."
rm -rf "$BUILD_DIR"

# WDA_PROJ is the shared appium-xcuitest-driver-vendored source under
# node_modules -- npm reinstalling/updating it wipes any edit made here, so
# this patch is (idempotently) re-applied on every build rather than once.
# productBundleIdentifier in the same file already reads WDA_PRODUCT_BUNDLE_IDENTIFIER
# at runtime (see _launch_env in wda_ctl.py) -- only this literal message
# string has no such override, so it's the one thing that actually needs a
# source edit rather than an env var.
echo "[build] Patching WDA source strings (status message)..."
FB_SESSION_CMDS="$WDA_PROJ/WebDriverAgentLib/Commands/FBSessionCommands.m"
sed -i '' 's/WebDriverAgent is ready to accept commands/rbserver is ready to accept commands/' "$FB_SESSION_CMDS"

echo "[build] xcodebuild build-for-testing (no signing, ~30-60s)..."
xcodebuild build-for-testing \
  -project "$WDA_PROJ/WebDriverAgent.xcodeproj" \
  -scheme WebDriverAgentRunner \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$BUILD_DIR" \
  IPHONEOS_DEPLOYMENT_TARGET=16.7 \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  GCC_TREAT_WARNINGS_AS_ERRORS=0 \
  | tail -20

if [ ! -d "$XCODE_APP" ]; then
  echo "[build] ERROR: app not found at $XCODE_APP after build" >&2
  exit 1
fi

echo "[build] Renaming build product to rbserver.app / rbserver.xctest..."
mv "$XCODE_APP" "$APP"
rm -rf "$APP/PlugIns/WebDriverAgentRunner.xctest.dSYM"
rm -f "$BUILD_DIR/Build/Products"/*.xctestrun
mv "$APP/WebDriverAgentRunner-Runner" "$APP/rbserver"
mv "$APP/PlugIns/WebDriverAgentRunner.xctest" "$APP/PlugIns/rbserver.xctest"
mv "$APP/PlugIns/rbserver.xctest/WebDriverAgentRunner" "$APP/PlugIns/rbserver.xctest/rbserver"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable rbserver" -c "Set :CFBundleName rbserver" -c "Set :CFBundleIdentifier com.rbserver.app" "$APP/Info.plist"
# CFBundleDisplayName isn't in the default Info.plist -- PlistBuddy's Set only
# works on existing keys, Add is needed to create a new one (confirmed live
# on GitHub Actions' macOS runner: `Set :CFBundleDisplayName` fails with
# "Does Not Exist" and aborts the whole build under `set -e`).
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string rbserver" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable rbserver" -c "Set :CFBundleName rbserver" -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/PlugIns/rbserver.xctest/Info.plist"

echo "[build] Bundling real iPhoneOS Swift Testing dependencies..."
FRAMEWORKS="$APP/Frameworks"
PLATFORM="$(xcrun --sdk iphoneos --show-sdk-platform-path)"

REAL_INTEROP="$PLATFORM/Developer/usr/lib/lib_TestingInterop.dylib"
REAL_FOUNDATION="$PLATFORM/Developer/Library/Frameworks/_Testing_Foundation.framework"

if [ ! -f "$REAL_INTEROP" ]; then
    echo "[build] ERROR: real lib_TestingInterop.dylib not found" >&2
    exit 1
fi

if [ ! -f "$REAL_FOUNDATION/_Testing_Foundation" ]; then
    echo "[build] ERROR: real _Testing_Foundation.framework not found" >&2
    exit 1
fi

echo "[build] Checking required Swift Testing symbol..."
if ! nm -g "$REAL_INTEROP" | grep -q '__swift_testing_getFallbackEventHandler'; then
    echo "[build] ERROR: required symbol missing from real library" >&2
    exit 1
fi

rm -f "$FRAMEWORKS/lib_TestingInterop.dylib"
cp "$REAL_INTEROP" "$FRAMEWORKS/lib_TestingInterop.dylib"

rm -rf "$FRAMEWORKS/_Testing_Foundation.framework"
ditto "$REAL_FOUNDATION" "$FRAMEWORKS/_Testing_Foundation.framework"

echo "[build] Swift Testing dependencies copied successfully"
echo "[build] Writing ad-hoc entitlements ($ENTITLEMENTS)..."
cat > "$ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>RBSERVER.$BUNDLE_ID</string>
	<key>com.apple.developer.team-identifier</key>
	<string>RBSERVER</string>
	<key>get-task-allow</key>
	<true/>
	<key>keychain-access-groups</key>
	<array>
		<string>RBSERVER.$BUNDLE_ID</string>
	</array>
	<key>com.apple.private.security.no-sandbox</key>
	<true/>
	<key>com.apple.private.skip-library-validation</key>
	<true/>
	<key>platform-application</key>
	<true/>
	<key>com.apple.security.get-task-allow</key>
	<true/>
</dict>
</plist>
PLIST

echo "[build] ldid-signing (ad-hoc, entitled)..."
# ldid signs one Mach-O binary at a time -- it doesn't take bundle directories.
# Every .framework/.dylib ANYWHERE in the app (including nested inside the
# .xctest plugin's own Frameworks dir -- e.g. WebDriverAgentLib.framework,
# which holds all of WDA's actual HTTP-server/automation code) must carry at
# least an ad-hoc signature or dyld refuses to map it at load time with
# "mapped file has no cdhash, completely unsigned" -- confirmed live even
# under a jailbreak's patched AMFI.
LDID=/opt/homebrew/bin/ldid

find "$APP" -name "*.framework" -type d | while read -r fw; do
  name="$(basename "$fw" .framework)"
  bin="$fw/$name"
  [ -f "$bin" ] && "$LDID" -S "$bin"
done
find "$APP" -name "*.dylib" -type f | while read -r dylib; do
  "$LDID" -S "$dylib"
done

# WebDriverAgentLib.framework holds all of WDA's actual HTTP-server/automation
# code, but its folder/binary name is baked into the consuming binary's dyld
# load commands at compile time -- renaming the files (without Xcode +
# install_name_tool to patch those load commands too) would break dyld
# resolution at launch. Only its cosmetic Info.plist identifier is safe to change.
WDA_LIB_PLIST="$APP/PlugIns/rbserver.xctest/Frameworks/WebDriverAgentLib.framework/Info.plist"
[ -f "$WDA_LIB_PLIST" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.rbserver.lib" "$WDA_LIB_PLIST"

XCTEST_BUNDLE="$APP/PlugIns/rbserver.xctest"
"$LDID" -S "$XCTEST_BUNDLE/rbserver"

"$LDID" -S"$ENTITLEMENTS" "$APP/rbserver"

echo "[build] Done. App at: $APP"
