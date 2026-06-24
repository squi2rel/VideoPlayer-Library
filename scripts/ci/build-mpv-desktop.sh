#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

target_os="${TARGET_OS:?TARGET_OS is required}"
target_arch="${TARGET_ARCH:?TARGET_ARCH is required}"
mpv_ref="${MPV_REF:?MPV_REF is required}"

require_mpv_release_ref "$mpv_ref"

asset_name="libmpv-$target_os-$target_arch"
source_url="https://github.com/mpv-player/mpv.git#$mpv_ref"
src_dir="$WORK_DIR/mpv-$target_os-$target_arch"
prefix="$WORK_DIR/mpv-prefix-$target_os-$target_arch"
package_dir="$WORK_DIR/$asset_name"
linux_cross_file="$WORK_DIR/meson-cross-linux-$target_arch.txt"

assert_not_nightly_url "$source_url"

common_meson_args=(
  --prefix="$prefix"
  --buildtype=release
  -Dlibmpv=true
  -Dgpl=true
  -Djavascript=enabled
  -Dlibarchive=enabled
  -Dlibbluray=enabled
  -Djpeg=enabled
  -Dlcms2=enabled
  -Drubberband=enabled
  -Duchardet=enabled
  -Dzimg=enabled
  -Dvulkan=enabled
)

clone_mpv() {
  rm -rf "$src_dir" "$prefix" "$package_dir"
  clone_git_tag https://github.com/mpv-player/mpv.git "$mpv_ref" "$src_dir"
  mkdir -p "$prefix" "$package_dir"
}

install_linux_deps() {
  if [[ "${SKIP_APT_INSTALL:-false}" == "true" ]]; then
    return
  fi

  local foreign_arch=""
  local cross_tool_packages=()

  case "$target_arch" in
    x86)
      foreign_arch="i386"
      cross_tool_packages=(gcc-multilib g++-multilib)
      ;;
    arm32)
      foreign_arch="armhf"
      cross_tool_packages=(gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf)
      ;;
  esac

  [[ -z "$foreign_arch" ]] || sudo dpkg --add-architecture "$foreign_arch"

  sudo apt-get update || true

  local common_packages=(
    build-essential ca-certificates curl git ninja-build pkg-config python3 python3-pip
    wayland-protocols zip
  )
  local linux_dev_packages=(
    libarchive-dev libasound2-dev libass-dev libavcodec-dev libavdevice-dev libavfilter-dev
    libavformat-dev libavutil-dev libbluray-dev libdrm-dev libegl-dev libgbm-dev libjpeg-dev
    liblcms2-dev liblua5.2-dev libplacebo-dev librubberband-dev libswresample-dev
    libswscale-dev libuchardet-dev libvulkan-dev libwayland-dev libx11-dev libxext-dev
    libxinerama-dev libxpresent-dev libxrandr-dev libxss-dev libxv-dev libzimg-dev
  )

  if [[ -n "$foreign_arch" ]]; then
    sudo apt-get install -y --no-install-recommends \
      "${common_packages[@]}" "${cross_tool_packages[@]}" \
      "${linux_dev_packages[@]/%/:$foreign_arch}"
  else
    sudo apt-get install -y --no-install-recommends \
      "${common_packages[@]}" "${linux_dev_packages[@]}" libmujs-dev
  fi

  install_pip_meson 1.6.1
}

install_macos_deps() {
  brew update
  brew install meson ninja pkg-config ffmpeg libass libarchive libbluray luajit mujs jpeg-turbo uchardet rubberband zimg little-cms2 libplacebo vulkan-headers vulkan-loader molten-vk zip

  export PKG_CONFIG_PATH="$(brew --prefix luajit)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
}

prepare_meson_subprojects() {
  cd "$src_dir"
  meson wrap update-db || true
  meson wrap install mujs || true
  meson subprojects download || true
}

write_linux_cross_file() {
  case "$target_arch" in
    x86)
      cat >"$linux_cross_file" <<EOF
[built-in options]
c_args = ['-m32']
cpp_args = ['-m32']
c_link_args = ['-m32']
cpp_link_args = ['-m32']

[binaries]
c = 'gcc'
cpp = 'g++'
ar = 'ar'
strip = 'strip'
pkgconfig = 'pkg-config'
pkg-config = 'pkg-config'

[host_machine]
system = 'linux'
cpu_family = 'x86'
cpu = 'i686'
endian = 'little'

[properties]
needs_exe_wrapper = false
pkg_config_libdir = ['/usr/lib/i386-linux-gnu/pkgconfig', '/usr/share/pkgconfig']
EOF
      ;;
    arm32)
      cat >"$linux_cross_file" <<EOF
[binaries]
c = 'arm-linux-gnueabihf-gcc'
cpp = 'arm-linux-gnueabihf-g++'
ar = 'arm-linux-gnueabihf-ar'
strip = 'arm-linux-gnueabihf-strip'
pkgconfig = 'pkg-config'
pkg-config = 'pkg-config'

[host_machine]
system = 'linux'
cpu_family = 'arm'
cpu = 'armv7'
endian = 'little'

[properties]
needs_exe_wrapper = true
pkg_config_libdir = ['/usr/lib/arm-linux-gnueabihf/pkgconfig', '/usr/share/pkgconfig']
EOF
      ;;
    *)
      die "unsupported Linux cross arch: $target_arch"
      ;;
  esac
}

build_and_install() {
  cd "$src_dir"
  local build_dir="$src_dir/build"
  local args=("${common_meson_args[@]}")
  local lua_backend

  case "$target_os" in
    linux) lua_backend=lua5.2 ;;
    macos) lua_backend=luajit ;;
    *) die "unsupported mpv desktop TARGET_OS: $target_os" ;;
  esac

  if [[ "$target_os" == "linux" && ( "$target_arch" == "x86" || "$target_arch" == "arm32" ) ]]; then
    write_linux_cross_file
    case "$target_arch" in
      x86) export PKG_CONFIG_LIBDIR="/usr/lib/i386-linux-gnu/pkgconfig:/usr/share/pkgconfig" ;;
      arm32) export PKG_CONFIG_LIBDIR="/usr/lib/arm-linux-gnueabihf/pkgconfig:/usr/share/pkgconfig" ;;
    esac
    args+=(
      --cross-file "$linux_cross_file"
      --force-fallback-for=mujs
      -Dmujs:werror=false
      -Dmujs:default_library=static
    )
  fi

  args+=("-Dlua=$lua_backend")
  meson setup "$build_dir" "${args[@]}"
  meson compile -C "$build_dir"
  meson install -C "$build_dir"
}

copy_matching_runtime_files() {
  local root="$1"
  local label="$2"
  shift 2

  local copied=0
  local file
  while IFS= read -r file; do
    cp -a "$file" "$package_dir/"
    copied=1
  done < <(find "$root" -maxdepth 4 \( -type f -o -type l \) "$@" | sort)

  [[ "$copied" -eq 1 ]] || die "could not find $label under $root"
}

package_mpv() {
  case "$target_os" in
    macos)
      copy_matching_runtime_files "$prefix/lib" "libmpv dylibs" -name 'libmpv*.dylib*'
      ;;
    linux)
      copy_matching_runtime_files "$prefix/lib" "libmpv shared libraries" -name 'libmpv*.so*'
      ;;
  esac

  require_mpv_runtime "$package_dir" "$target_os"
  zip_package "$package_dir" "$asset_name"
}

case "$target_os" in
  linux)
    install_linux_deps
    ;;
  macos)
    install_macos_deps
    ;;
  *)
    die "unsupported mpv desktop TARGET_OS: $target_os"
    ;;
esac

need_cmd git
need_cmd meson
need_cmd ninja
need_cmd zip

clone_mpv
prepare_meson_subprojects
build_and_install
package_mpv
