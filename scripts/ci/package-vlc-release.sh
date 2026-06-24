#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

target_os="${TARGET_OS:?TARGET_OS is required}"
target_arch="${TARGET_ARCH:?TARGET_ARCH is required}"
vlc_version="${VLC_VERSION:?VLC_VERSION is required}"
android_libvlc_version="${ANDROID_LIBVLC_VERSION:-}"

require_vlc_release_version "$vlc_version"
if [[ -n "$android_libvlc_version" ]]; then
  require_android_libvlc_release_version "$android_libvlc_version"
fi

asset_name="libvlc-$target_os-$target_arch"
package_dir="$WORK_DIR/$asset_name"
rm -rf "$package_dir"
mkdir -p "$package_dir"

package_windows() {
  need_cmd 7z
  need_cmd zip

  local release_dir suffix html source_url archive extract_dir root
  case "$target_arch" in
    x86) suffix="win32" ;;
    x64) suffix="win64" ;;
    arm64) suffix="winarm64" ;;
    *) die "unsupported Windows arch: $target_arch" ;;
  esac

  release_dir="https://download.videolan.org/pub/videolan/vlc/$vlc_version/$suffix/"
  html="$WORK_DIR/vlc-$vlc_version-$suffix.html"
  download_url "$release_dir" "$html"
  source_url="$(select_href "$release_dir" "vlc-${vlc_version}-${suffix}\\.(zip|7z)$" "$html")"
  assert_not_nightly_url "$source_url"

  archive="$WORK_DIR/$(basename "$source_url")"
  extract_dir="$WORK_DIR/extract-$asset_name"
  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"
  download_url "$source_url" "$archive"
  7z x -y "-o$extract_dir" "$archive" >/dev/null

  root="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [[ -n "$root" ]] || die "could not find extracted VLC root"
  cp -a "$root/libvlc.dll" "$package_dir/"
  cp -a "$root/libvlccore.dll" "$package_dir/"
  [[ -d "$root/plugins" ]] || die "could not find VLC Windows plugins directory"
  cp -a "$root/plugins" "$package_dir/plugins"

  require_vlc_runtime "$package_dir" windows true
  zip_package "$package_dir" "$asset_name"
}

package_macos() {
  need_cmd hdiutil
  need_cmd zip

  local release_dir suffix html source_url archive mount_dir app dylib lib_dir plugins_dir
  case "$target_arch" in
    x64) suffix="intel64" ;;
    arm64) suffix="arm64" ;;
    *) die "unsupported macOS arch: $target_arch" ;;
  esac

  release_dir="https://download.videolan.org/pub/videolan/vlc/$vlc_version/macosx/"
  html="$WORK_DIR/vlc-$vlc_version-macosx.html"
  download_url "$release_dir" "$html"
  source_url="$(select_href "$release_dir" "vlc-${vlc_version}-${suffix}\\.dmg$" "$html")"
  assert_not_nightly_url "$source_url"

  archive="$WORK_DIR/$(basename "$source_url")"
  mount_dir="$WORK_DIR/mnt-$asset_name"
  rm -rf "$mount_dir"
  mkdir -p "$mount_dir"
  download_url "$source_url" "$archive"

  hdiutil attach "$archive" -mountpoint "$mount_dir" -nobrowse -quiet
  trap 'hdiutil detach "$mount_dir" -quiet || true' EXIT
  app="$(find "$mount_dir" -maxdepth 2 -type d -name 'VLC.app' | head -n 1)"
  [[ -n "$app" ]] || die "could not find VLC.app in dmg"

  dylib="$(find "$app/Contents" -type f -name 'libvlc*.dylib' | head -n 1)"
  [[ -n "$dylib" ]] || die "could not find VLC macOS dylib"
  lib_dir="$(dirname "$dylib")"
  cp -a "$lib_dir"/. "$package_dir/"

  plugins_dir="$(find "$app/Contents" -type d -name plugins | head -n 1)"
  [[ -d "$plugins_dir" ]] || die "could not find VLC macOS plugins directory"
  cp -a "$plugins_dir" "$package_dir/plugins"

  hdiutil detach "$mount_dir" -quiet
  trap - EXIT

  require_vlc_runtime "$package_dir" macos true
  zip_package "$package_dir" "$asset_name"
}

package_android() {
  need_cmd unzip
  need_cmd zip

  [[ -n "$android_libvlc_version" ]] || die "ANDROID_LIBVLC_VERSION is required for Android"

  local abi="$target_arch"
  local source_url archive extract_dir jni_dir
  case "$abi" in
    arm64-v8a | armeabi-v7a | x86 | x86_64) ;;
    *) die "unsupported Android ABI: $abi" ;;
  esac

  source_url="https://repo1.maven.org/maven2/org/videolan/android/libvlc-all/$android_libvlc_version/libvlc-all-$android_libvlc_version.aar"
  assert_not_nightly_url "$source_url"
  [[ "$android_libvlc_version" != *eap* ]] || die "Android libvlc eap versions are not allowed by default"

  archive="$WORK_DIR/libvlc-all-$android_libvlc_version.aar"
  extract_dir="$WORK_DIR/extract-$asset_name"
  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"
  download_url "$source_url" "$archive"
  unzip -q "$archive" -d "$extract_dir"

  jni_dir="$extract_dir/jni/$abi"
  [[ -d "$jni_dir" ]] || die "AAR does not contain jni/$abi"
  cp -a "$jni_dir"/. "$package_dir/"

  VLC_ANDROID_BRIDGE_OUT_DIR="$WORK_DIR/vlc-android-bridge-$abi" \
    TARGET_ARCH="$abi" \
    "$SCRIPT_DIR/build-vlc-android-bridge.sh" >/dev/null
  cp -a "$WORK_DIR/vlc-android-bridge-$abi/libvlc_jvm_bridge.so" "$package_dir/"

  require_vlc_runtime "$package_dir" android false
  require_any_file "$package_dir" "VLC Android JVM bridge" "libvlc_jvm_bridge.so"
  zip_package "$package_dir" "$asset_name"
}

case "$target_os" in
  windows) package_windows ;;
  macos) package_macos ;;
  android) package_android ;;
  linux) exec "$SCRIPT_DIR/build-vlc-linux.sh" ;;
  *) die "unsupported TARGET_OS: $target_os" ;;
esac
