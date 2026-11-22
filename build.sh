#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
output_dir="${1:-$project_dir/../../outputs}"
app_dir="$output_dir/拾影.app"
sdk_path="${PICKVIDEO_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$sdk_path" ]]; then
  sdk_path="$(/usr/bin/xcrun --show-sdk-path)"
fi
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$project_dir/.build/module-cache"
/usr/bin/swiftc -sdk "$sdk_path" -swift-version 5 -O -parse-as-library -module-cache-path "$project_dir/.build/module-cache" -target arm64-apple-macosx14.0 "$project_dir"/Sources/*.swift -o "$app_dir/Contents/MacOS/PickVideo" -framework SwiftUI -framework WebKit -framework AppKit -framework Security
cp "$project_dir/Resources/yt-dlp" "$app_dir/Contents/Resources/yt-dlp"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
if [[ -d "$project_dir/Resources/engine-plugins" ]]; then
  # Package source-only plugins as ZIPs; importing them cannot mutate the signed bundle.
  rm -rf "$app_dir/Contents/Resources/engine-plugins"
  mkdir -p "$app_dir/Contents/Resources/engine-plugins"
  /usr/bin/python3 - "$project_dir/Resources/engine-plugins/pickvideo" "$app_dir/Contents/Resources/engine-plugins/pickvideo.zip" <<'PY'
import pathlib, sys, zipfile
root = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(sys.argv[2], 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    for file in sorted(root.rglob('*.py')):
        archive.write(file, file.relative_to(root))
PY
fi
if [[ -f "$project_dir/Resources/AppIcon.icns" ]]; then
  cp "$project_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
fi
if [[ -d "$project_dir/Resources/licenses" ]]; then
  cp -R "$project_dir/Resources/licenses" "$app_dir/Contents/Resources/"
fi
chmod +x "$app_dir/Contents/MacOS/PickVideo" "$app_dir/Contents/Resources/yt-dlp"
/usr/bin/codesign --force --sign - "$app_dir"
"$app_dir/Contents/MacOS/PickVideo" --self-test
echo "Built: $app_dir"
