#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
set -eu
package=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
identity=${CODE_SIGN_IDENTITY:-}
if [ -z "$identity" ]; then
    identity=$(/usr/bin/security find-identity -v -p codesigning | awk '/"Apple Development:/ { id = $2; count++ } END { if (count == 1) print id }')
fi
if [ -z "$identity" ]; then
    echo "Using ad hoc signing. Set CODE_SIGN_IDENTITY for stable permissions across builds." >&2
    identity=-
fi
scratch="$package/.build"
output="$package/build"
export CLANG_MODULE_CACHE_PATH="$scratch/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$scratch/ModuleCache"
swift build --package-path "$package" --scratch-path "$scratch" \
    --cache-path "$scratch/cache" --config-path "$scratch/config" \
    --security-path "$scratch/security" --disable-sandbox -debug-info-format none -c release \
    -Xswiftc -file-prefix-map -Xswiftc "$package=/src"
bin=$(swift build --package-path "$package" --scratch-path "$scratch" \
    --cache-path "$scratch/cache" --config-path "$scratch/config" \
    --security-path "$scratch/security" --disable-sandbox -debug-info-format none -c release \
    -Xswiftc -file-prefix-map -Xswiftc "$package=/src" --show-bin-path)
app="$output/Dumb Monitor.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/DumbMonitor" "$app/Contents/MacOS/DumbMonitor.new"
mv -f "$app/Contents/MacOS/DumbMonitor.new" "$app/Contents/MacOS/DumbMonitor"
cp "$package/Info.plist" "$app/Contents/Info.plist"
cp "$package/Resources/AppIcon.icns" "$app/Contents/Resources/"
cp "$package/LICENSE" "$app/Contents/Resources/LICENSE"
cp -R "$package/Resources/en.lproj" "$package/Resources/zh-Hans.lproj" "$app/Contents/Resources/"
cp "$bin/s9-input" "$output/s9-input.new"
mv -f "$output/s9-input.new" "$output/s9-input"
/usr/bin/codesign --force --sign "$identity" "$app"
/usr/bin/codesign --force --sign "$identity" "$output/s9-input"
printf 'Built %s\n' "$app" "$output/s9-input"
