#!/usr/bin/env bash
# gen-info-plist.sh — Generate Info.plist for the .app bundle.
# Used by `make bundle`.

product_name="${PRODUCT_NAME:-NeuraMind}"
product_executable="${PRODUCT_EXECUTABLE:-$product_name}"
bundle_id="${BUNDLE_ID:-com.neuramind.app}"
app_version="${APP_VERSION:-0.2.0}"
app_build="${APP_BUILD:-1}"
icon_basename="${ICON_BASENAME:-neuramind}"

cat <<'EOF' | sed \
    -e "s#__PRODUCT_NAME__#${product_name}#g" \
    -e "s#__PRODUCT_EXECUTABLE__#${product_executable}#g" \
    -e "s#__BUNDLE_ID__#${bundle_id}#g" \
    -e "s#__APP_VERSION__#${app_version}#g" \
    -e "s#__APP_BUILD__#${app_build}#g" \
    -e "s#__ICON_BASENAME__#${icon_basename}#g"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>__PRODUCT_EXECUTABLE__</string>
    <key>CFBundleIdentifier</key>
    <string>__BUNDLE_ID__</string>
    <key>CFBundleName</key>
    <string>__PRODUCT_NAME__</string>
    <key>CFBundleDisplayName</key>
    <string>__PRODUCT_NAME__</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>__APP_VERSION__</string>
    <key>CFBundleVersion</key>
    <string>__APP_BUILD__</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>__ICON_BASENAME__</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>NeuraMind captures screenshots to build your activity timeline. No data leaves your device without your permission.</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>NeuraMind reads window titles and focused elements to provide richer context in your activity log.</string>
</dict>
</plist>
EOF
