#!/bin/bash

# Creates a proper macOS app bundle structure

set -e

APP_NAME="Remotastic"
APP_DISPLAY_NAME="遥控器助手"
APP_BUNDLE="${APP_DISPLAY_NAME}.app"

# Check for new binary name first, fall back to old for backward compatibility
if [ ! -f "$APP_NAME" ] && [ ! -f "SiriRemote" ]; then
    echo "Error: $APP_NAME executable not found."
    echo "Please build first with: ./build.sh"
    exit 1
fi

# Use new binary if available, otherwise use old
if [ -f "$APP_NAME" ]; then
    BINARY_NAME="$APP_NAME"
else
    BINARY_NAME="SiriRemote"
    echo "Note: Using old binary name 'SiriRemote' for backward compatibility"
fi

echo "正在创建应用程序包：$APP_BUNDLE"

# Create bundle structure
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy executable
cp "$BINARY_NAME" "${APP_BUNDLE}/Contents/MacOS/$APP_NAME"

# Copy icon if it exists
if [ -f "Remotastic.icns" ]; then
    cp "Remotastic.icns" "${APP_BUNDLE}/Contents/Resources/Remotastic.icns"
    echo "Icon added to app bundle"
elif [ -f "SiriRemote.icns" ]; then
    cp "SiriRemote.icns" "${APP_BUNDLE}/Contents/Resources/Remotastic.icns"
    echo "Icon added to app bundle"
fi

# Create proper Info.plist with all required keys
echo "Creating Info.plist..."
cat > "${APP_BUNDLE}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>com.remotastic.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>遥控器助手</string>
	<key>CFBundleDisplayName</key>
	<string>遥控器助手</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleVersion</key>
	<string>1.0</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleIconFile</key>
	<string>Remotastic</string>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © 2025 遥控器助手开源贡献者</string>
	<key>LSMinimumSystemVersion</key>
	<string>11.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>遥控器助手需要使用蓝牙，以连接 Siri 遥控器并读取触控板和按键输入。</string>
	<key>NSBluetoothPeripheralUsageDescription</key>
	<string>遥控器助手需要使用蓝牙，以连接 Siri 遥控器并读取触控板和按键输入。</string>
</dict>
</plist>
EOF

# Make executable
chmod +x "${APP_BUNDLE}/Contents/MacOS/$APP_NAME"

# Use a stable Apple Development identity when one is installed. Accessibility
# and Input Monitoring permissions are tied to the app's designated code
# requirement; ad-hoc signing ties that identity to a changing binary hash and
# causes macOS to ask again after every rebuild.
PREFERRED_SIGN_IDENTITY="Apple Development: Created via API (7KA2GLZ966)"
SIGN_IDENTITY="${REMOTASTIC_SIGN_IDENTITY:-$PREFERRED_SIGN_IDENTITY}"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$SIGN_IDENTITY\""; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F '"' '/Apple Development:/ { print $2; exit }')
fi

if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
    echo "Signed with: $SIGN_IDENTITY"
else
    codesign --force --deep --sign - "$APP_BUNDLE"
    echo "Warning: no Apple Development identity found; used ad-hoc signing"
fi

echo ""
echo "✓ App bundle created: $APP_BUNDLE"
echo ""
echo "You can now:"
echo "  1. Double-click $APP_BUNDLE to run it"
echo "  2. Or run: open $APP_BUNDLE"
echo ""
echo "Note: You'll need to grant Accessibility permissions in:"
echo "  System Settings → Privacy & Security → Accessibility"
