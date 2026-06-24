#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

target_abi="${TARGET_ARCH:?TARGET_ARCH is required}"
mpv_android_ref="${MPV_ANDROID_REF:?MPV_ANDROID_REF is required}"

require_mpv_android_release_ref "$mpv_android_ref"

asset_name="libmpv-android-$target_abi"
source_url="https://github.com/mpv-android/mpv-android.git#$mpv_android_ref"
src_dir="$WORK_DIR/mpv-android-$target_abi"
package_dir="$WORK_DIR/$asset_name"

assert_not_nightly_url "$source_url"

case "$target_abi" in
  arm64-v8a) mpv_arch="arm64" ;;
  armeabi-v7a) mpv_arch="armv7l" ;;
  x86) mpv_arch="x86" ;;
  x86_64) mpv_arch="x86_64" ;;
  *) die "unsupported Android ABI: $target_abi" ;;
esac

install_deps() {
  if [[ "${SKIP_APT_INSTALL:-false}" == "true" ]]; then
    return
  fi

  sudo apt-get update
  sudo apt-get install -y --no-install-recommends \
    autoconf automake autopoint bash build-essential ca-certificates cmake curl gettext git \
    libtool nasm ninja-build openjdk-17-jdk pkg-config python3 python3-pip unzip yasm zip

  install_pip_meson 1.6.1
}

collect_so_files() {
  mkdir -p "$package_dir"

  local copied=0
  local preferred_dirs=(
    "$src_dir/app/src/main/jniLibs/$target_abi"
    "$src_dir/app/build/intermediates/merged_native_libs"
    "$src_dir/buildscripts/prefix/$mpv_arch/lib"
    "$src_dir/buildscripts/prefix/$target_abi/lib"
  )

  local dir
  for dir in "${preferred_dirs[@]}"; do
    if [[ -d "$dir" ]]; then
      while IFS= read -r so; do
        cp -f "$so" "$package_dir/"
        copied=1
      done < <(find "$dir" -type f -name '*.so')
    fi
  done

  if [[ "$copied" -eq 0 ]]; then
    while IFS= read -r so; do
      cp -f "$so" "$package_dir/"
      copied=1
    done < <(find "$src_dir" -type f -name '*.so')
  fi

  [[ "$copied" -eq 1 ]] || die "mpv-android build produced no shared libraries"
}

install_deps
rm -rf "$src_dir" "$package_dir"
mkdir -p "$package_dir"
clone_git_tag https://github.com/mpv-android/mpv-android.git "$mpv_android_ref" "$src_dir"

unset TARGET_ARCH
cd "$src_dir/buildscripts"
./download.sh
./buildall.sh --arch "$mpv_arch" mpv

collect_so_files
require_mpv_runtime "$package_dir" android
zip_package "$package_dir" "$asset_name"
