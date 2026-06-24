#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

target_abi="${TARGET_ARCH:?TARGET_ARCH is required}"
android_api="${ANDROID_API:-21}"
src_file="${VLC_ANDROID_BRIDGE_SRC:-$SCRIPT_DIR/vlc_jvm_bridge.c}"
out_dir="${VLC_ANDROID_BRIDGE_OUT_DIR:-$WORK_DIR/vlc-android-bridge/$target_abi}"
lib_name="libvlc_jvm_bridge.so"

case "$target_abi" in
  arm64-v8a) target_triple="aarch64-linux-android" ;;
  armeabi-v7a) target_triple="armv7a-linux-androideabi" ;;
  x86) target_triple="i686-linux-android" ;;
  x86_64) target_triple="x86_64-linux-android" ;;
  *) die "unsupported Android ABI for VLC bridge: $target_abi" ;;
esac

find_android_ndk() {
  local candidate
  for candidate in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}" "${ANDROID_NDK:-}" "$HOME/android-ndk"; do
    if [[ -n "$candidate" && -d "$candidate/toolchains/llvm/prebuilt" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  local root
  for root in "${ANDROID_HOME:-}/ndk" "${ANDROID_SDK_ROOT:-}/ndk" "$HOME/android-sdk/ndk"; do
    if [[ -d "$root" ]]; then
      find "$root" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1
      return
    fi
  done
}

find_toolchain_bin() {
  local ndk="$1"
  local prebuilt="$ndk/toolchains/llvm/prebuilt"
  local host_dir

  for host_dir in "$prebuilt/linux-x86_64" "$prebuilt/darwin-x86_64" "$prebuilt/darwin-arm64"; do
    if [[ -d "$host_dir/bin" ]]; then
      printf '%s\n' "$host_dir/bin"
      return
    fi
  done

  host_dir="$(find "$prebuilt" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [[ -n "$host_dir" && -d "$host_dir/bin" ]] || die "could not find Android NDK LLVM toolchain under $prebuilt"
  printf '%s\n' "$host_dir/bin"
}

ndk="$(find_android_ndk)"
[[ -n "$ndk" ]] || die "Android NDK not found. Set ANDROID_NDK_HOME, ANDROID_NDK_ROOT, or ANDROID_NDK."
toolchain_bin="$(find_toolchain_bin "$ndk")"
cc="$toolchain_bin/${target_triple}${android_api}-clang"
strip_tool="$toolchain_bin/llvm-strip"

[[ -f "$src_file" ]] || die "VLC Android bridge source not found: $src_file"
[[ -x "$cc" ]] || die "Android clang not found: $cc"

mkdir -p "$out_dir"
log "build VLC Android JVM bridge for $target_abi with NDK $ndk"
"$cc" \
  -shared \
  -fPIC \
  -O2 \
  -Wall \
  -Wextra \
  -Wl,-soname,"$lib_name" \
  "$src_file" \
  -o "$out_dir/$lib_name" \
  -ldl \
  -llog

if [[ -x "$strip_tool" ]]; then
  "$strip_tool" --strip-unneeded "$out_dir/$lib_name"
fi

require_any_file "$out_dir" "$lib_name" "$lib_name"
printf '%s\n' "$out_dir/$lib_name"
