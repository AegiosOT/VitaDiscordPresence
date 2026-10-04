#!/usr/bin/env bash
#
# Builds VitaPresence.app with only the Command Line Tools (no Xcode), signs it, and optionally notarizes,
# installs and zips it. Run with --help for the options.
#
# The app is assembled outside the repository (in ~/Library/Caches by default): the repository may live in
# an iCloud-synced folder, where bundles pick up Finder metadata that makes codesign fail. Nothing is
# written into the repository except the optional zip in dist/.

set -euo pipefail

readonly app_name="VitaPresence"
readonly bundle_id="io.github.aegiosot.VitaPresence"
readonly minimum_macos="13.0"

# With CDPATH set, cd prints the directory it found, which would end up in script_dir.
script_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
package_dir="$(dirname "$script_dir")"
repo_dir="$(dirname "$package_dir")"
readonly script_dir package_dir repo_dir
readonly info_plist="$package_dir/Resources/Info.plist"
readonly icon_source="$repo_dir/pc/VitaPresence-GUI/Resources/Icon.ico"
readonly build_root="${VITAPRESENCE_BUILD_DIR:-$HOME/Library/Caches/$bundle_id}"

usage() {
    cat <<EOF
Usage: scripts/build-app.sh [options]

Builds, assembles and signs $app_name.app in the build directory
($build_root).

Options:
  --arch ARCH          arm64, x86_64 or universal (default: universal)
  --version X.Y.Z      version to write into Info.plist (default: the one in Resources/Info.plist)
  --sign IDENTITY      codesign identity (default: "-", ad hoc). A real identity also enables the
                       hardened runtime and a secure timestamp, as notarization requires.
  --notarize PROFILE   notarize with this notarytool keychain profile, then staple the ticket
                       (needs a real --sign identity)
  --install            copy the app to /Applications, or ~/Applications if that isn't writable
  --zip                write dist/$app_name-<version>-macOS.zip next to Package.swift
  -h, --help           show this help

Environment:
  VITAPRESENCE_BUILD_DIR   build directory (default: ~/Library/Caches/$bundle_id)
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

step() {
    echo "==> $*"
}

# Fails unless option "$1" is followed by a value.
require_value() {
    [[ $# -ge 2 && -n $2 && $2 != --* ]] || die "$1 needs a value (see --help)"
}

# Zips the app to "$1". macOS re-attaches provenance attributes to the files right after `xattr -c`; without
# --norsrc they would end up as ._ files that break the signature for anyone unzipping with another tool.
zip_app() {
    ditto -c -k --norsrc --keepParent "$app" "$1"
}

arch="universal"
version=""
identity="-"
notary_profile=""
install=false
make_zip=false

while (($# > 0)); do
    case "$1" in
        --arch) require_value "$@"; arch="$2"; shift 2 ;;
        --version) require_value "$@"; version="$2"; shift 2 ;;
        --sign) require_value "$@"; identity="$2"; shift 2 ;;
        --notarize) require_value "$@"; notary_profile="$2"; shift 2 ;;
        --install) install=true; shift ;;
        --zip) make_zip=true; shift ;;
        -h | --help) usage; exit 0 ;;
        *) die "unknown option '$1' (see --help)" ;;
    esac
done

case "$arch" in
    arm64 | x86_64) arch_flags=(--arch "$arch"); expected_archs="$arch" ;;
    universal) arch_flags=(--arch arm64 --arch x86_64); expected_archs="arm64 x86_64" ;;
    *) die "--arch must be arm64, x86_64 or universal" ;;
esac
for tool in swift xcrun xcode-select codesign lipo otool install_name_tool plutil sips iconutil ditto xattr; do
    command -v "$tool" >/dev/null || die "$tool not found; install the Command Line Tools with: xcode-select --install"
done
# The version of the SDK SwiftPM links with: SDKROOT, or else the macosx SDK of the selected developer directory.
sdk_version="$(xcrun --sdk "${SDKROOT:-macosx}" --show-sdk-version)" || die "can't determine the macOS SDK version"
[[ -n $sdk_version ]] || die "can't determine the macOS SDK version"
if [[ -z $version ]]; then
    version="$(plutil -extract CFBundleShortVersionString raw -o - "$info_plist")"
fi
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the version must look like X.Y.Z, not '$version'"
if [[ -n $notary_profile && $identity == "-" ]]; then
    die "--notarize needs a real signing identity, such as --sign \"Developer ID Application: Name (TEAMID)\""
fi
[[ -f $icon_source ]] || die "app icon not found at $icon_source"

readonly app="$build_root/$app_name.app"
readonly work_dir="$build_root/work"
readonly executable="$app/Contents/MacOS/$app_name"
readonly plist="$app/Contents/Info.plist"

# --- Build ---

step "Building $app_name $version ($arch)"
swift_args=(--package-path "$package_dir" --scratch-path "$build_root/swiftpm" -c release --product "$app_name")
swift_args+=("${arch_flags[@]}")
# SwiftPM's default build system records the deployment target as the SDK version, so macOS would treat the
# app as built with the macOS 13 SDK and apply old AppKit behaviour. Record the real SDK instead.
swift build "${swift_args[@]}" \
    -Xlinker -platform_version -Xlinker macos -Xlinker "$minimum_macos" -Xlinker "$sdk_version"
binary="$(swift build "${swift_args[@]}" --show-bin-path)/$app_name"
built_archs="$(lipo -archs "$binary" | tr ' ' '\n' | sort | xargs)"
[[ $built_archs == "$expected_archs" ]] || die "built for '$built_archs' instead of '$expected_archs'"

# --- Assemble ---

step "Assembling $app"
rm -rf "$app" "$work_dir"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$work_dir"
cp "$binary" "$executable"

# SwiftPM adds an rpath into the toolchain, which an installed app must not depend on (it uses the Swift
# runtime in macOS). Universal binaries list it once per slice, and one delete removes it from every slice.
toolchain_rpaths() {
    otool -l "$executable" | awk -v prefix="$(xcode-select -p)/" '
        $2 == "LC_RPATH" { in_rpath = 1; next }
        in_rpath && $1 == "path" {
            in_rpath = 0
            sub(/^ *path /, ""); sub(/ \(offset [0-9]+\)$/, "")
            if (index($0, prefix) == 1 && !seen[$0]++) print
        }'
}
while IFS= read -r rpath; do
    # install_name_tool warns that this invalidates the signature, which is expected: the bundle is signed below.
    output="$(install_name_tool -delete_rpath "$rpath" "$executable" 2>&1)" || die "install_name_tool: $output"
done < <(toolchain_rpaths)
[[ -z $(toolchain_rpaths) ]] || die "the toolchain rpath is still in $executable"

cp "$info_plist" "$plist"
plutil -replace CFBundleShortVersionString -string "$version" "$plist"
plutil -replace CFBundleVersion -string "$version" "$plist"
printf 'APPL????' >"$app/Contents/PkgInfo"

# The Windows client's .ico holds several sizes; sips reads the largest, 256 px. There is no larger source,
# so the 256@2x slot gets an upscaled copy.
iconset="$work_dir/AppIcon.iconset"
mkdir -p "$iconset"
sips -s format png "$icon_source" --out "$work_dir/icon.png" >/dev/null
for slot in 16x16:16 16x16@2x:32 32x32:32 32x32@2x:64 128x128:128 128x128@2x:256 256x256:256 256x256@2x:512; do
    size="${slot#*:}"
    sips -z "$size" "$size" "$work_dir/icon.png" --out "$iconset/icon_${slot%:*}.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

# --- Sign ---

step "Signing (identity: $identity)"
sign_args=(--force --sign "$identity" --identifier "$bundle_id")
if [[ $identity != "-" ]]; then
    sign_args+=(--options runtime --timestamp)
fi
xattr -cr "$app" # Stray extended attributes make strict verification fail.
codesign "${sign_args[@]}" "$app"
codesign --verify --strict --verbose=2 "$app"
plutil -lint "$plist"

if [[ -n $notary_profile ]]; then
    step "Notarizing (this usually takes a few minutes)"
    notary_zip="$work_dir/$app_name-notarize.zip"
    zip_app "$notary_zip"
    result="$(xcrun notarytool submit "$notary_zip" --keychain-profile "$notary_profile" --wait --output-format json)"
    status="$(plutil -extract status raw -o - - <<<"$result")"
    if [[ $status != "Accepted" ]]; then
        submission="$(plutil -extract id raw -o - - <<<"$result")"
        die "notarization finished with status '$status'; see: xcrun notarytool log $submission --keychain-profile $notary_profile"
    fi
    xcrun stapler staple "$app"
fi

# --- Deliver ---

if $install; then
    destination="/Applications"
    [[ -w $destination ]] || destination="$HOME/Applications"
    step "Installing to $destination"
    mkdir -p "$destination"
    rm -rf "${destination:?}/$app_name.app"
    ditto "$app" "$destination/$app_name.app"
    if pgrep -x "$app_name" >/dev/null; then
        echo "$app_name is running; quit and reopen it to use the new version."
    fi
fi

if $make_zip; then
    zip_path="$package_dir/dist/$app_name-$version-macOS.zip"
    step "Zipping to $zip_path"
    mkdir -p "$(dirname "$zip_path")"
    rm -f "$zip_path"
    zip_app "$zip_path"
fi

signature_info="$(codesign -dv --verbose=2 "$app" 2>&1)"
signer="$(awk '/^Authority=/ { sub(/^Authority=/, ""); print; exit }' <<<"$signature_info")"
if [[ -z $signer ]]; then
    signer="$(awk '/^Signature=/ { sub(/^Signature=/, ""); print; exit }' <<<"$signature_info")"
fi

echo
echo "App:        $app"
echo "Version:    $version"
echo "Archs:      $(lipo -archs "$executable")"
echo "Size:       $(du -sh "$app" | cut -f1)"
echo "Signature:  $signer ($bundle_id)"
