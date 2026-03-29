#!/usr/bin/env bash
# gen-info-plist.sh — Generate Info.plist for the .app bundle.
# Used by `make bundle`.

cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>NeuraMind</string>
    <key>CFBundleIdentifier</key>
    <string>com.neuramind.app</string>
    <key>CFBundleName</key>
    <string>NeuraMind</string>
    <key>CFBundleDisplayName</key>
    <string>NeuraMind</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>neuramind</string>
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
