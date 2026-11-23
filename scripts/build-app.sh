#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd -P)"
dist="$project_root/dist"
target="$dist/WindDesk.app"
identity="${WINDDESK_SIGN_IDENTITY:--}"
app_profile="${WINDDESK_APP_PROVISIONING_PROFILE:-}"
widget_profile="${WINDDESK_WIDGET_PROVISIONING_PROFILE:-}"

if [[ "$identity" != "-" ]] && [[ ! -f "$app_profile" || ! -f "$widget_profile" ]]; then
    printf '%s\n' "指定证书签名时，请为应用和小组件分别提供包含 group.com.winddesk.market 的配置描述文件。" >&2
    exit 1
fi

mkdir -p "$dist"
stage="$(mktemp -d "$dist/.winddesk-build.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

# Keep local toolchain caches with the rest of the build products.
export CLANG_MODULE_CACHE_PATH="$project_root/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
build=(swift build --package-path "$project_root" --configuration release
       --cache-path "$project_root/.build/swiftpm-cache" --manifest-cache local)
"${build[@]}" --product WindDesk
"${build[@]}" --product WindDeskWidget
bin_dir="$("${build[@]}" --show-bin-path)"

bundle="$stage/WindDesk.app"
widget="$bundle/Contents/PlugIns/WindDeskWidget.appex"
mkdir -p "$bundle/Contents/MacOS" "$widget/Contents/MacOS"
install -m 755 "$bin_dir/WindDesk" "$bundle/Contents/MacOS/WindDesk"
install -m 755 "$bin_dir/WindDeskWidget" "$widget/Contents/MacOS/WindDeskWidget"
install -m 644 "$project_root/macOS/Info.plist" "$bundle/Contents/Info.plist"
install -m 644 "$project_root/macOS/Widget-Info.plist" "$widget/Contents/Info.plist"
app_entitlements="$project_root/macOS/WindDesk.entitlements"
widget_entitlements="$project_root/macOS/WindDeskWidget.entitlements"

prepare_signing_profile() {
    local profile="$1" bundle_path="$2" entitlements="$3" name="$4"
    local decoded="$stage/$name-profile.plist" signed_entitlements="$stage/$name.entitlements"
    local bundle_id application_id
    security cms -D -i "$profile" -o "$decoded"
    bundle_id="$(plutil -extract CFBundleIdentifier raw "$bundle_path/Contents/Info.plist")"
    application_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$decoded")"
    if [[ ! "$application_id" =~ ^[A-Za-z0-9]+\.[A-Za-z0-9.]+$ || "$application_id" != *."$bundle_id" ]]; then
        printf '%s\n' "配置描述文件必须授权标识为 $bundle_id 的应用。" >&2
        exit 1
    fi
    install -m 644 "$profile" "$bundle_path/Contents/embedded.provisionprofile"
    install -m 644 "$entitlements" "$signed_entitlements"
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $application_id" "$signed_entitlements"
    printf '%s\n' "$signed_entitlements"
}

if [[ "$identity" != "-" ]]; then
    app_entitlements="$(prepare_signing_profile "$app_profile" "$bundle" "$app_entitlements" app)"
    widget_entitlements="$(prepare_signing_profile "$widget_profile" "$widget" "$widget_entitlements" widget)"
else
    # Local builds use one read-only file entitlement for the widget's quote snapshot.
    /usr/libexec/PlistBuddy -c "Add :WindDeskWidgetLocalCache bool true" "$bundle/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :WindDeskWidgetLocalCache bool true" "$widget/Contents/Info.plist"
    app_entitlements="$stage/local-app.entitlements"
    plutil -create xml1 "$app_entitlements"
    widget_entitlements="$project_root/macOS/WindDeskWidget.local.entitlements"
fi

plutil -lint "$bundle/Contents/Info.plist" "$widget/Contents/Info.plist" "$app_entitlements" "$widget_entitlements"
codesign --force --sign "$identity" --generate-entitlement-der --entitlements "$widget_entitlements" "$widget"
codesign --force --sign "$identity" --generate-entitlement-der --entitlements "$app_entitlements" "$bundle"
codesign --verify --strict "$widget"
codesign --verify --deep --strict "$bundle"

# Publish a complete, verified bundle in one rename on the destination volume.
swift - "$bundle" "$target" <<'SWIFT'
import Darwin
import Foundation

let source = CommandLine.arguments[1]
let destination = CommandLine.arguments[2]
let replacing = FileManager.default.fileExists(atPath: destination)
if replacing {
    let resource = URL(fileURLWithPath: destination)
    let info = try resource.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
    guard info.isSymbolicLink == false, info.isDirectory == true,
          Bundle(url: resource)?.bundleIdentifier == "com.winddesk.menubar" else {
        fputs("已有同名文件不是 WindDesk 构建产物。\n", stderr)
        exit(1)
    }
}
let mode = UInt32(replacing ? RENAME_SWAP : RENAME_EXCL)
guard renamex_np(source, destination, mode) == 0 else {
    perror("无法发布 WindDesk.app")
    exit(1)
}
SWIFT

printf '%s\n' "$target"
