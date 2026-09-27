#!/usr/bin/env bash
# Builds Cinmux.app from this checkout with SwiftPM and assembles the bundle:
#
#   macos/scripts/build-app.sh [output-directory]    (default: macos/build)
#
# Contents/MacOS/Cinmux is the app, Contents/Helpers/cinmux the CLI and TUI.
# SWIFT_BUILD_FLAGS adds flags to `swift build` (Homebrew passes --disable-sandbox).
set -euo pipefail

package=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$package/.." && pwd)
out=${1:-$package/build}
read -r -a flags <<<"${SWIFT_BUILD_FLAGS:-}"
version=$(sed -n 's/^public let cinmuxVersion = "\(.*\)"$/\1/p' "$package/Sources/CinmuxCore/Environment.swift")
[[ -n $version ]] || { echo "error: cannot read cinmuxVersion" >&2; exit 1; }

swift build --package-path "$package" -c release ${flags[@]+"${flags[@]}"} --product cinmux
swift build --package-path "$package" -c release ${flags[@]+"${flags[@]}"} --product CinmuxApp
bin=$(swift build --package-path "$package" -c release ${flags[@]+"${flags[@]}"} --show-bin-path)

app="$out/Cinmux.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources/omp"
cp "$bin/CinmuxApp" "$app/Contents/MacOS/Cinmux"
cp "$bin/cinmux" "$app/Contents/Helpers/cinmux"
cp "$repo/resources/cinmux.tmux.conf" "$app/Contents/Resources/"
cp "$repo/resources/omp/cinmux-activity.ts" "$app/Contents/Resources/omp/"
cp "$package/Resources/AppIcon.icns" "$package/Resources/SymbolsNerdFontMono-Regular.ttf" "$package/Resources/SymbolsNerdFont-LICENSE" \
	"$app/Contents/Resources/"
# SwiftTerm's resource bundle (its Metal shader source) belongs in Resources, where SwiftTerm looks.
for bundle in "$bin"/*.bundle; do
	if [[ -e $bundle ]]; then cp -R "$bundle" "$app/Contents/Resources/"; fi
done
sed "s/@VERSION@/$version/g" "$package/Resources/Info.plist" >"$app/Contents/Info.plist"
printf 'APPL????' >"$app/Contents/PkgInfo"

# Ad-hoc signatures: Apple silicon refuses unsigned code, and a locally built
# app is never quarantined, so Gatekeeper does not need a Developer ID here.
codesign --force --sign - --timestamp=none "$app/Contents/Helpers/cinmux"
codesign --force --sign - --timestamp=none "$app"
echo "$app"
