#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

target_os="${TARGET_OS:?TARGET_OS is required}"
target_arch="${TARGET_ARCH:?TARGET_ARCH is required}"
mpv_ref="${MPV_REF:?MPV_REF is required}"

require_mpv_release_ref "$mpv_ref"
unset TARGET_ARCH

asset_name="libmpv-$target_os-$target_arch"
source_url="https://github.com/mpv-player/mpv.git#$mpv_ref"
src_dir="$WORK_DIR/mpv-$target_os-$target_arch"
prefix="$WORK_DIR/mpv-prefix-$target_os-$target_arch"
package_dir="$WORK_DIR/$asset_name"
deps_dir="$WORK_DIR/mpv-deps-$target_os-$target_arch"
download_cache="${DOWNLOAD_CACHE:-$WORK_DIR/downloads}"
desktop_cross_file="$WORK_DIR/meson-cross-$target_os-$target_arch.txt"

ffmpeg_ref="${FFMPEG_REF:-n7.1.2}"
dav1d_ref="${DAV1D_REF:-1.5.3}"
lcms2_ref="${LCMS2_REF:-lcms2.19.1}"
libxml2_ref="${LIBXML2_REF:-v2.15.3}"
fontconfig_ref="${FONTCONFIG_REF:-2.17.1}"
libass_ref="${LIBASS_REF:-0.17.5}"
libplacebo_ref="${LIBPLACEBO_REF:-v6.338.2}"
rubberband_ref="${RUBBERBAND_REF:-v4.0.0}"
uchardet_ref="${UCHARDET_REF:-v0.0.8}"
zimg_ref="${ZIMG_REF:-release-3.0.6}"
libsixel_ref="${LIBSIXEL_REF:-v1.9.0}"
libdisplay_info_ref="${LIBDISPLAY_INFO_REF:-0.1.1}"
nvcodec_ref="${NVCODEC_REF:-n13.0.19.0}"
vulkan_sdk_ref="${VULKAN_SDK_REF:-vulkan-sdk-1.4.350.1}"
vulkan_headers_ref="${VULKAN_HEADERS_REF:-$vulkan_sdk_ref}"
shaderc_ref="${SHADERC_REF:-v2026.2}"

assert_not_nightly_url "$source_url"

host_triplet=""
host_cpu_family=""
host_cpu=""
ffmpeg_arch=""
ffmpeg_target_os="$target_os"
needs_cross_file=false
meson_cross_args=()
cmake_common_args=()
ffmpeg_extra_args=()
pkg_config_libdir="$prefix/lib/pkgconfig:$prefix/share/pkgconfig"

job_count() {
  getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || printf '2\n'
}

download_tar() {
  local url="$1"
  local out="$2"

  mkdir -p "$download_cache"
  if [[ -s "$download_cache/$(basename "$out")" ]]; then
    cp "$download_cache/$(basename "$out")" "$out"
    return
  fi

  download_url "$url" "$out"
  cp "$out" "$download_cache/$(basename "$out")"
}

extract_tar_once() {
  local url="$1"
  local archive_name="$2"
  local expected_dir="$3"

  if [[ -d "$expected_dir" ]]; then
    return
  fi

  local archive="$deps_dir/$archive_name"
  mkdir -p "$(dirname "$expected_dir")"
  rm -f "$archive"
  download_tar "$url" "$archive"
  tar -C "$(dirname "$expected_dir")" -xf "$archive"
  [[ -d "$expected_dir" ]] || die "expected $archive_name to extract to $expected_dir"
}

clone_or_update() {
  local repo_url="$1"
  local dest="$2"
  local ref="${3:-}"
  local extra="${4:-}"

  if [[ -d "$dest/.git" ]]; then
    return
  fi

  local args=(--depth 1)
  [[ -z "$ref" ]] || args+=(--branch "$ref")
  [[ "$extra" != "recursive" ]] || args+=(--recursive --shallow-submodules)
  git_clone_retry "${args[@]}" "$repo_url" "$dest"
}

builddir() {
  local dir="$1/builddir"
  rm -rf "$dir"
  mkdir -p "$dir"
  cd "$dir"
}

install_build() {
  if [[ -f build.ninja ]]; then
    ninja
    ninja install
  else
    make -j"$(job_count)"
    make install
  fi
}

setup_toolchain() {
  unset PKG_CONFIG_SYSROOT_DIR

  case "$target_os:$target_arch" in
    linux:x64)
      host_triplet="x86_64-linux-gnu"
      host_cpu_family="x86_64"
      host_cpu="x86_64"
      ffmpeg_arch="x86_64"
      pkg_config_libdir="$pkg_config_libdir:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
      export CC="${CC:-gcc}"
      export CXX="${CXX:-g++}"
      export AR="${AR:-ar}"
      export RANLIB="${RANLIB:-ranlib}"
      export STRIP="${STRIP:-strip}"
      ;;
    linux:x86)
      host_triplet="i686-linux-gnu"
      host_cpu_family="x86"
      host_cpu="i686"
      ffmpeg_arch="x86"
      needs_cross_file=true
      export CC="${CC:-gcc}"
      export CXX="${CXX:-g++}"
      export AR="${AR:-ar}"
      export RANLIB="${RANLIB:-ranlib}"
      export STRIP="${STRIP:-strip}"
      export CFLAGS="${CFLAGS:-} -m32"
      export CXXFLAGS="${CXXFLAGS:-} -m32"
      export LDFLAGS="${LDFLAGS:-} -m32"
      ffmpeg_extra_args+=(--extra-cflags=-m32 --extra-ldflags=-m32)
      pkg_config_libdir="$pkg_config_libdir:/usr/lib/i386-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
      ;;
    linux:arm64)
      host_triplet="aarch64-linux-gnu"
      host_cpu_family="aarch64"
      host_cpu="aarch64"
      ffmpeg_arch="aarch64"
      pkg_config_libdir="$pkg_config_libdir:/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
      export CC="${CC:-gcc}"
      export CXX="${CXX:-g++}"
      export AR="${AR:-ar}"
      export RANLIB="${RANLIB:-ranlib}"
      export STRIP="${STRIP:-strip}"
      ;;
    linux:arm32)
      host_triplet="arm-linux-gnueabihf"
      host_cpu_family="arm"
      host_cpu="armv7"
      ffmpeg_arch="arm"
      needs_cross_file=true
      export CC="${CC:-arm-linux-gnueabihf-gcc}"
      export CXX="${CXX:-arm-linux-gnueabihf-g++}"
      export AR="${AR:-arm-linux-gnueabihf-ar}"
      export RANLIB="${RANLIB:-arm-linux-gnueabihf-ranlib}"
      export STRIP="${STRIP:-arm-linux-gnueabihf-strip}"
      export CFLAGS="${CFLAGS:-} -mfpu=vfpv3-d16 -mfloat-abi=hard"
      export CXXFLAGS="${CXXFLAGS:-} -mfpu=vfpv3-d16 -mfloat-abi=hard"
      ffmpeg_extra_args+=(--enable-cross-compile --cross-prefix=arm-linux-gnueabihf- --cpu=armv7-a --extra-cflags=-mfpu=vfpv3-d16 --extra-cflags=-mfloat-abi=hard)
      pkg_config_libdir="$pkg_config_libdir:/usr/lib/arm-linux-gnueabihf/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
      ;;
    macos:x64)
      host_triplet="x86_64-apple-darwin"
      host_cpu_family="x86_64"
      host_cpu="x86_64"
      ffmpeg_arch="x86_64"
      ffmpeg_target_os="darwin"
      export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
      export CC="${CC:-clang}"
      export CXX="${CXX:-clang++}"
      export AR="${AR:-ar}"
      export RANLIB="${RANLIB:-ranlib}"
      export STRIP="${STRIP:-strip}"
      ;;
    macos:arm64)
      host_triplet="aarch64-apple-darwin"
      host_cpu_family="aarch64"
      host_cpu="aarch64"
      ffmpeg_arch="aarch64"
      ffmpeg_target_os="darwin"
      export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
      export CC="${CC:-clang}"
      export CXX="${CXX:-clang++}"
      export AR="${AR:-ar}"
      export RANLIB="${RANLIB:-ranlib}"
      export STRIP="${STRIP:-strip}"
      ;;
    *)
      die "unsupported mpv desktop target: $target_os/$target_arch"
      ;;
  esac

  export CFLAGS="-O3 -pipe -fPIC -I$prefix/include ${CFLAGS:-}"
  export CXXFLAGS="-O3 -pipe -fPIC -I$prefix/include ${CXXFLAGS:-}"
  export LDFLAGS="-L$prefix/lib ${LDFLAGS:-}"
  export PKG_CONFIG_LIBDIR="$pkg_config_libdir"
  export PKG_CONFIG_PATH=
  export LIBRARY_PATH="$prefix/lib:${LIBRARY_PATH:-}"

  if [[ "$target_os" == "linux" ]]; then
    export LDFLAGS="$LDFLAGS -static-libgcc -static-libstdc++"
  fi
}

write_meson_cross_file() {
  "$needs_cross_file" || return 0

  case "$target_arch" in
    x86)
      cat >"$desktop_cross_file" <<EOF
[built-in options]
buildtype = 'release'
default_library = 'static'
prefer_static = true
b_ndebug = 'if-release'
optimization = '3'
c_args = ['-O3', '-pipe', '-fPIC', '-I$prefix/include', '-m32']
cpp_args = ['-O3', '-pipe', '-fPIC', '-I$prefix/include', '-m32']
c_link_args = ['-L$prefix/lib', '-m32', '-static-libgcc', '-static-libstdc++']
cpp_link_args = ['-L$prefix/lib', '-m32', '-static-libgcc', '-static-libstdc++']

[binaries]
c = ['gcc', '-m32']
cpp = ['g++', '-m32']
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
pkg_config_libdir = ['$prefix/lib/pkgconfig', '$prefix/share/pkgconfig', '/usr/lib/i386-linux-gnu/pkgconfig', '/usr/lib/pkgconfig', '/usr/share/pkgconfig']
EOF
      ;;
    arm32)
      cat >"$desktop_cross_file" <<EOF
[built-in options]
buildtype = 'release'
default_library = 'static'
prefer_static = true
b_ndebug = 'if-release'
optimization = '3'
c_args = ['-O3', '-pipe', '-fPIC', '-I$prefix/include', '-mfpu=vfpv3-d16', '-mfloat-abi=hard']
cpp_args = ['-O3', '-pipe', '-fPIC', '-I$prefix/include', '-mfpu=vfpv3-d16', '-mfloat-abi=hard']
c_link_args = ['-L$prefix/lib', '-static-libgcc', '-static-libstdc++']
cpp_link_args = ['-L$prefix/lib', '-static-libgcc', '-static-libstdc++']

[binaries]
c = 'arm-linux-gnueabihf-gcc'
cpp = 'arm-linux-gnueabihf-g++'
ar = 'arm-linux-gnueabihf-ar'
strip = 'arm-linux-gnueabihf-strip'
exe_wrapper = 'qemu-arm'
pkgconfig = 'pkg-config'
pkg-config = 'pkg-config'

[host_machine]
system = 'linux'
cpu_family = 'arm'
cpu = 'armv7'
endian = 'little'

[properties]
needs_exe_wrapper = true
pkg_config_libdir = ['$prefix/lib/pkgconfig', '$prefix/share/pkgconfig', '/usr/lib/arm-linux-gnueabihf/pkgconfig', '/usr/lib/pkgconfig', '/usr/share/pkgconfig']
EOF
      ;;
  esac

  meson_cross_args=(--cross-file "$desktop_cross_file")
}

set_cmake_args() {
  local cmake_ar="$AR"
  local cmake_ranlib="$RANLIB"
  if [[ "$cmake_ar" != */* ]]; then
    cmake_ar="$(command -v "$cmake_ar")"
  fi
  if [[ "$cmake_ranlib" != */* ]]; then
    cmake_ranlib="$(command -v "$cmake_ranlib")"
  fi

  cmake_common_args=(
    -Wno-dev
    -GNinja
    -DCMAKE_INSTALL_PREFIX="$prefix"
    -DCMAKE_INSTALL_LIBDIR=lib
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=OFF
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    -DCMAKE_C_COMPILER="$CC"
    -DCMAKE_CXX_COMPILER="$CXX"
    -DCMAKE_AR="$cmake_ar"
    -DCMAKE_RANLIB="$cmake_ranlib"
    -DCMAKE_C_FLAGS="$CFLAGS"
    -DCMAKE_CXX_FLAGS="$CXXFLAGS"
    -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS"
    -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS"
  )

  if "$needs_cross_file"; then
    cmake_common_args+=(
      -DCMAKE_SYSTEM_NAME=Linux
      -DCMAKE_SYSTEM_PROCESSOR="$host_cpu_family"
    )
  fi
}

reset_dirs() {
  rm -rf "$src_dir" "$prefix" "$package_dir" "$deps_dir"
  mkdir -p "$prefix" "$package_dir" "$deps_dir" "$download_cache"
}

install_linux_deps() {
  if [[ "${SKIP_APT_INSTALL:-false}" != "true" ]]; then
    local foreign_arch=""
    local dev_arch_suffix=""
    local cross_tool_packages=()

    case "$target_arch" in
      x86)
        foreign_arch="i386"
        dev_arch_suffix=":i386"
        cross_tool_packages=(gcc-multilib g++-multilib)
        ;;
      arm32)
        foreign_arch="armhf"
        dev_arch_suffix=":armhf"
        cross_tool_packages=(gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf qemu-user)
        ;;
    esac

    [[ -z "$foreign_arch" ]] || sudo dpkg --add-architecture "$foreign_arch"
    sudo apt-get update || true

    local build_packages=(
      autoconf automake autopoint build-essential ca-certificates cmake curl git libtool
      m4 make nasm ninja-build pkg-config python3 python3-pip tar unzip wget xz-utils
      hwdata yasm zip
    )
    local platform_dev_packages=(
      libasound2-dev libjack-jackd2-dev libopenal-dev libpipewire-0.3-dev libpulse-dev libsdl2-dev libsndio-dev
      libcaca-dev libdrm-dev libegl-dev libgbm-dev
      libgl-dev libgles-dev libvulkan-dev libwayland-dev libxkbcommon-dev libx11-dev
      libxext-dev libxfixes-dev libxpresent-dev libxrandr-dev libxss-dev libxv-dev
      libva-dev libvdpau-dev
    )
    local install_packages=("${build_packages[@]}" "${cross_tool_packages[@]}" oss4-dev wayland-protocols)
    local package
    for package in "${platform_dev_packages[@]}"; do
      install_packages+=("$package$dev_arch_suffix")
    done

    sudo apt-get install -y --no-install-recommends \
      "${install_packages[@]}"
  fi

  install_pip_meson 1.6.1
  install_pip_package glad2
}

install_macos_deps() {
  brew update
  brew install autoconf automake cmake libtool meson nasm ninja pkg-config wget yasm zip
  install_pip_meson 1.6.1
  install_pip_package glad2
}

meson_setup_static() {
  local source="$1"
  local build="$2"
  shift 2

  meson setup "$build" "$source" \
    --prefix "$prefix" \
    --libdir lib \
    --buildtype=release \
    -Ddefault_library=static \
    -Dprefer_static=true \
    -Doptimization=3 \
    -Db_ndebug=if-release \
    "${meson_cross_args[@]+"${meson_cross_args[@]}"}" \
    "$@"
}

cxx_private_libs() {
  case "$target_os" in
    linux)
      printf '%s\n' "-lstdc++"
      ;;
    macos)
      printf '%s\n' "-lc++"
      ;;
    *)
      printf '%s\n' "-lstdc++"
      ;;
  esac
}

zlib_static_archive() {
  [[ "$target_os" == "linux" ]] || return 0

  local archive
  archive="$(find "$prefix/lib" -maxdepth 1 -name 'libz.a' | sort | head -1)"
  [[ -f "$archive" ]] || die "could not find static libz for $target_os/$target_arch"
  printf '%s\n' "$archive"
}

static_cxx_archive() {
  [[ "$target_os" == "linux" ]] || return 0

  local cxx_args=()
  if [[ "$target_arch" == "x86" ]]; then
    cxx_args=(-m32)
  fi

  local archive
  archive="$("$CXX" "${cxx_args[@]+"${cxx_args[@]}"}" -print-file-name=libstdc++.a)"
  [[ -f "$archive" ]] || die "could not find static libstdc++ for $CXX"
  printf '%s\n' "$archive"
}

normalize_pc_static_cxx_runtime() {
  [[ "$target_os" == "linux" ]] || return 0

  local pc_file="$1"

  [[ -f "$pc_file" ]] || return 0
  sed -i.bak -E \
    -e "s#-Wl,-Bstatic[[:space:]]+##g" \
    -e "s#[[:space:]]+-Wl,-Bdynamic##g" \
    -e "s#(^|[[:space:]])/[^[:space:]]*/libstdc\+\+\.a([[:space:]]|$)#\1-lstdc++\2#g" \
    "$pc_file"
  rm -f "$pc_file.bak"
}

normalize_pc_static_zlib_runtime() {
  [[ "$target_os" == "linux" ]] || return 0

  local archive
  archive="$(zlib_static_archive)"

  local pc_file="$1"
  [[ -f "$pc_file" ]] || return 0
  sed -i.bak -E \
    -e "s#(^|[[:space:]])-lz([[:space:]]|$)#\1$archive\2#g" \
    "$pc_file"
  rm -f "$pc_file.bak"
}

prepare_pc_static_cxx_runtime_for_mpv() {
  [[ "$target_os" == "linux" ]] || return 0

  local archive
  archive="$(static_cxx_archive)"

  local pc_file
  shopt -s nullglob
  for pc_file in "$prefix"/lib/pkgconfig/*.pc; do
    sed -i.bak -E "s#(^|[[:space:]])-lstdc\+\+([[:space:]]|$)#\1$archive\2#g" "$pc_file"
    rm -f "$pc_file.bak"
  done
  shopt -u nullglob
}

prepare_pc_static_zlib_runtime_for_mpv() {
  [[ "$target_os" == "linux" ]] || return 0

  local pc_file
  shopt -s nullglob
  for pc_file in "$prefix"/lib/pkgconfig/*.pc; do
    normalize_pc_static_zlib_runtime "$pc_file"
  done
  shopt -u nullglob
}

build_zlib_ng() {
  local version=2.2.5
  extract_tar_once "https://github.com/zlib-ng/zlib-ng/archive/refs/tags/$version.tar.gz" "zlib-ng-$version.tar.gz" "$deps_dir/zlib-ng-$version"
  builddir "$deps_dir/zlib-ng-$version"
  cmake .. "${cmake_common_args[@]}" -DZLIB_COMPAT=ON -DZLIB_ENABLE_TESTS=OFF -DZLIBNG_ENABLE_TESTS=OFF -DBUILD_TESTING=OFF
  install_build

  local pc_file
  for pc_file in "$prefix"/lib/pkgconfig/zlib*.pc; do
    [[ -f "$pc_file" ]] || continue
    normalize_pc_static_zlib_runtime "$pc_file"
  done
}

build_dav1d() {
  clone_or_update https://code.videolan.org/videolan/dav1d.git "$deps_dir/dav1d" "$dav1d_ref"
  meson_setup_static "$deps_dir/dav1d" "$deps_dir/dav1d/builddir" \
    -Denable_tools=false \
    -Denable_tests=false
  meson compile -C "$deps_dir/dav1d/builddir"
  meson install -C "$deps_dir/dav1d/builddir"
}

build_lcms2() {
  clone_or_update https://github.com/mm2/Little-CMS.git "$deps_dir/lcms2" "$lcms2_ref"
  meson_setup_static "$deps_dir/lcms2" "$deps_dir/lcms2/builddir" \
    -Djpeg=disabled \
    -Dtiff=disabled \
    -Dtests=disabled \
    -Dutils=false \
    -Dversionedlibs=false
  meson compile -C "$deps_dir/lcms2/builddir"
  meson install -C "$deps_dir/lcms2/builddir"
}

build_lua52() {
  local version=5.2.4
  extract_tar_once "https://www.lua.org/ftp/lua-$version.tar.gz" "lua-$version.tar.gz" "$deps_dir/lua-$version"
  cd "$deps_dir/lua-$version"

  local lua_sys_cflags="-DLUA_USE_LINUX"
  [[ "$target_os" != "macos" ]] || lua_sys_cflags="-DLUA_USE_MACOSX"

  make -C src clean || true
  make -C src a \
    CC="$CC" \
    AR="$AR rcu" \
    RANLIB="$RANLIB" \
    MYCFLAGS="$CFLAGS -DLUA_COMPAT_ALL $lua_sys_cflags -fPIC" \
    MYLDFLAGS="$LDFLAGS"

  mkdir -p "$prefix/include" "$prefix/lib"
  install -m 0644 src/liblua.a "$prefix/lib/"
  install -m 0644 src/lua.h src/luaconf.h src/lualib.h src/lauxlib.h src/lua.hpp "$prefix/include/"

  mkdir -p "$prefix/lib/pkgconfig"
  cat >"$prefix/lib/pkgconfig/lua5.2.pc" <<EOF
prefix=$prefix
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: Lua
Description: Lua language engine
Version: $version
Libs: -L\${libdir} -llua -lm
Cflags: -I\${includedir}
EOF
  cp "$prefix/lib/pkgconfig/lua5.2.pc" "$prefix/lib/pkgconfig/lua-5.2.pc"
}

build_rubberband() {
  clone_or_update https://github.com/breakfastquay/rubberband.git "$deps_dir/rubberband" "$rubberband_ref"
  meson_setup_static "$deps_dir/rubberband" "$deps_dir/rubberband/builddir" \
    -Dfft=builtin \
    -Dresampler=builtin \
    -Djni=disabled \
    -Dladspa=disabled \
    -Dlv2=disabled \
    -Dvamp=disabled \
    -Dcmdline=disabled \
    -Dtests=disabled
  meson compile -C "$deps_dir/rubberband/builddir"
  meson install -C "$deps_dir/rubberband/builddir"

  local pc_file="$prefix/lib/pkgconfig/rubberband.pc"
  [[ -f "$pc_file" ]] || die "rubberband pkg-config file was not installed: $pc_file"
  if grep -q '^Libs\.private:' "$pc_file"; then
    sed -i.bak -E "s|^Libs\.private:.*|Libs.private: $(cxx_private_libs) -lm|" "$pc_file"
    rm -f "$pc_file.bak"
  else
    printf 'Libs.private: %s -lm\n' "$(cxx_private_libs)" >>"$pc_file"
  fi
  normalize_pc_static_cxx_runtime "$pc_file"
}

build_uchardet() {
  clone_or_update https://gitlab.freedesktop.org/uchardet/uchardet.git "$deps_dir/uchardet" "$uchardet_ref"
  builddir "$deps_dir/uchardet"
  cmake .. "${cmake_common_args[@]}" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_BINARY=OFF \
    -DBUILD_SHARED_LIBS=OFF
  install_build

  local pc_file="$prefix/lib/pkgconfig/uchardet.pc"
  [[ -f "$pc_file" ]] || die "uchardet pkg-config file was not installed: $pc_file"
  if grep -q '^Libs\.private:' "$pc_file"; then
    sed -i.bak -E "s|^Libs\.private:.*|Libs.private: $(cxx_private_libs)|" "$pc_file"
    rm -f "$pc_file.bak"
  else
    printf 'Libs.private: %s\n' "$(cxx_private_libs)" >>"$pc_file"
  fi
  normalize_pc_static_cxx_runtime "$pc_file"
}

build_zimg() {
  clone_or_update https://github.com/sekrit-twc/zimg.git "$deps_dir/zimg" "$zimg_ref"
  cd "$deps_dir/zimg"
  ./autogen.sh

  local args=(
    --prefix="$prefix"
    --libdir="$prefix/lib"
    --enable-static
    --disable-shared
    --disable-dependency-tracking
    --disable-testapp
    --disable-example
    --disable-unit-test
  )

  if [[ "$target_os" == "linux" && "$needs_cross_file" == "true" ]]; then
    args+=(--host="$host_triplet")
  fi

  make distclean >/dev/null 2>&1 || true
  STL_LIBS="$(cxx_private_libs)" ./configure "${args[@]}"
  install_build

  local pc_file="$prefix/lib/pkgconfig/zimg.pc"
  [[ -f "$pc_file" ]] || die "zimg pkg-config file was not installed: $pc_file"
  sed -i.bak -E "s|^Libs\.private:.*|Libs.private: $(cxx_private_libs) -lm|" "$pc_file"
  rm -f "$pc_file.bak"
  normalize_pc_static_cxx_runtime "$pc_file"
}

build_libsixel() {
  [[ "$target_os" == "linux" ]] || return 0

  clone_or_update https://github.com/libsixel/libsixel.git "$deps_dir/libsixel" "$libsixel_ref"
  cd "$deps_dir/libsixel"
  make distclean >/dev/null 2>&1 || true

  ./configure \
    --host="$host_triplet" \
    --prefix="$prefix" \
    --libdir="$prefix/lib" \
    --enable-static \
    --disable-shared \
    --disable-dependency-tracking \
    --disable-img2sixel \
    --disable-sixel2png \
    --disable-python \
    --disable-tests \
    --without-gd \
    --without-gdk-pixbuf2 \
    --without-libcurl \
    --without-jpeg \
    --without-png
  install_build
}

build_libdisplay_info() {
  [[ "$target_os" == "linux" ]] || return 0

  clone_or_update https://gitlab.freedesktop.org/emersion/libdisplay-info.git "$deps_dir/libdisplay-info" "$libdisplay_info_ref"
  sed -i.bak \
    -e "/subdir('di-edid-decode')/d" \
    -e "/subdir('test')/d" \
    "$deps_dir/libdisplay-info/meson.build"
  rm -f "$deps_dir/libdisplay-info/meson.build.bak"

  meson_setup_static "$deps_dir/libdisplay-info" "$deps_dir/libdisplay-info/builddir"
  meson compile -C "$deps_dir/libdisplay-info/builddir"
  meson install -C "$deps_dir/libdisplay-info/builddir"
}

build_nvcodec_headers() {
  [[ "$target_os" == "linux" ]] || return 0
  [[ "$target_arch" != "arm32" ]] || return 0

  clone_or_update https://github.com/FFmpeg/nv-codec-headers.git "$deps_dir/nv-codec-headers" "$nvcodec_ref"
  make -C "$deps_dir/nv-codec-headers" PREFIX="$prefix" install
}

build_vulkan_headers() {
  [[ "$target_os" == "linux" ]] || return 0

  clone_or_update https://github.com/KhronosGroup/Vulkan-Headers.git "$deps_dir/Vulkan-Headers" "$vulkan_headers_ref"
  builddir "$deps_dir/Vulkan-Headers"
  cmake .. "${cmake_common_args[@]}"
  install_build

  local vulkan_version="${vulkan_headers_ref#vulkan-sdk-}"
  mkdir -p "$prefix/lib/pkgconfig"
  cat >"$prefix/lib/pkgconfig/vulkan.pc" <<EOF
prefix=$prefix
exec_prefix=\${prefix}
includedir=\${prefix}/include

Name: Vulkan-Loader
Description: Vulkan loader using packaged release headers and the host libvulkan
Version: $vulkan_version
Libs: -lvulkan
Cflags: -I\${includedir}
EOF
}

shaderc_deps_ready() {
  local dep
  for dep in \
    third_party/abseil_cpp \
    third_party/effcee \
    third_party/glslang \
    third_party/googletest \
    third_party/re2 \
    third_party/spirv-headers \
    third_party/spirv-tools; do
    [[ -d "$deps_dir/shaderc/$dep/.git" ]] || return 1
  done
}

sync_shaderc_deps() {
  local attempt

  for attempt in 1 2 3 4 5; do
    (cd "$deps_dir/shaderc" && ./utils/git-sync-deps) || true
    if shaderc_deps_ready; then
      return 0
    fi
    [[ "$attempt" -eq 5 ]] && break
    log "shaderc git-sync-deps did not fetch every dependency, retrying in 5s"
    sleep 5
  done

  die "shaderc git-sync-deps did not fetch every dependency"
}

build_shaderc() {
  [[ "$target_os" == "linux" ]] || return 0

  clone_or_update https://github.com/google/shaderc.git "$deps_dir/shaderc" "$shaderc_ref"
  sync_shaderc_deps
  builddir "$deps_dir/shaderc"
  cmake .. "${cmake_common_args[@]}" \
    -DSHADERC_SKIP_TESTS=ON \
    -DSHADERC_SKIP_EXAMPLES=ON \
    -DSHADERC_SKIP_EXECUTABLES=ON \
    -DSHADERC_SKIP_COPYRIGHT_CHECK=ON \
    -DSHADERC_ENABLE_WERROR_COMPILE=OFF
  install_build
  rm -f "$prefix"/lib/libshaderc_shared.so* "$prefix"/lib/libSPIRV-Tools-shared.so*

  local pc_file
  local private_libs
  private_libs="$(cxx_private_libs) -lm -lpthread"
  for pc_file in \
    "$prefix/lib/pkgconfig/shaderc.pc" \
    "$prefix/lib/pkgconfig/shaderc_static.pc" \
    "$prefix/lib/pkgconfig/shaderc_combined.pc"; do
    [[ -f "$pc_file" ]] || continue
    sed -i.bak -E "s|^Libs:.*|Libs: -L\${libdir} -lshaderc_combined|" "$pc_file"
    if grep -q '^Libs\.private:' "$pc_file"; then
      sed -i.bak -E "s|^Libs\.private:.*|Libs.private: $private_libs|" "$pc_file"
    else
      printf 'Libs.private: %s\n' "$private_libs" >>"$pc_file"
    fi
    rm -f "$pc_file.bak"
    normalize_pc_static_cxx_runtime "$pc_file"
  done
  [[ -f "$prefix/lib/pkgconfig/shaderc.pc" ]] || die "shaderc pkg-config file was not installed"
  [[ -f "$prefix/lib/libshaderc_combined.a" ]] || die "shaderc_combined static library was not installed"
}

build_ffmpeg() {
  clone_or_update https://github.com/FFmpeg/FFmpeg.git "$deps_dir/ffmpeg" "$ffmpeg_ref"
  builddir "$deps_dir/ffmpeg"

  local ffmpeg_ldflags="$LDFLAGS"
  if [[ "$target_os" == "linux" ]]; then
    ffmpeg_ldflags="${ffmpeg_ldflags// -static-libgcc/}"
    ffmpeg_ldflags="${ffmpeg_ldflags// -static-libstdc++/}"
  fi

  local args=(
    --prefix="$prefix"
    --pkg-config=pkg-config
    --pkg-config-flags=--static
    --target-os="$ffmpeg_target_os"
    --arch="$ffmpeg_arch"
    --cc="$CC"
    --cxx="$CXX"
    --ar="$AR"
    --ranlib="$RANLIB"
    --strip="$STRIP"
    --enable-static
    --disable-shared
    --enable-pic
    --disable-doc
    --disable-debug
    --disable-programs
    --disable-autodetect
    --enable-runtime-cpudetect
    --enable-gpl
    --enable-zlib
    --enable-libdav1d
    --enable-libzimg
    --enable-muxer=spdif
    --enable-encoder=mjpeg,png
    --extra-cflags="$CFLAGS"
    --extra-ldflags="$ffmpeg_ldflags"
    "${ffmpeg_extra_args[@]+"${ffmpeg_extra_args[@]}"}"
  )

  if [[ "$target_os" == "macos" ]]; then
    args+=(--enable-audiotoolbox --enable-videotoolbox --enable-lto=thin)
  else
    args+=(
      --enable-alsa
      --enable-libjack
      --enable-libpulse
      --enable-openal
      --enable-opengl
      --enable-sdl2
      --enable-libdrm
      --enable-vaapi
      --enable-vdpau
      --enable-vulkan
      --enable-librubberband
    )
    if [[ "$target_arch" != "arm32" ]]; then
      args+=(--enable-ffnvcodec)
    fi
  fi
  if [[ "$target_os" == "linux" ]] && pkg-config --exists libplacebo; then
    args+=(--enable-libplacebo)
  fi

  if ! PKG_CONFIG_LIBDIR="$pkg_config_libdir" PKG_CONFIG_PATH= LDFLAGS="$ffmpeg_ldflags" ../configure "${args[@]}"; then
    if [[ -f ffbuild/config.log ]]; then
      log "FFmpeg configure failed; tailing ffbuild/config.log"
      tail -200 ffbuild/config.log || true
    fi
    return 1
  fi
  install_build

  local pc_file
  for pc_file in "$prefix"/lib/pkgconfig/libav*.pc "$prefix"/lib/pkgconfig/libsw*.pc; do
    normalize_pc_static_cxx_runtime "$pc_file"
  done
}

build_freetype() {
  local version=2.14.1
  extract_tar_once "https://download.savannah.gnu.org/releases/freetype/freetype-$version.tar.xz" "freetype-$version.tar.xz" "$deps_dir/freetype-$version"
  meson_setup_static "$deps_dir/freetype-$version" "$deps_dir/freetype-$version/builddir" \
    -Dbrotli=disabled \
    -Dbzip2=disabled \
    -Dharfbuzz=disabled \
    -Dpng=disabled
  meson compile -C "$deps_dir/freetype-$version/builddir"
  meson install -C "$deps_dir/freetype-$version/builddir"
}

build_fribidi() {
  local version=1.0.16
  extract_tar_once "https://github.com/fribidi/fribidi/releases/download/v$version/fribidi-$version.tar.xz" "fribidi-$version.tar.xz" "$deps_dir/fribidi-$version"
  meson_setup_static "$deps_dir/fribidi-$version" "$deps_dir/fribidi-$version/builddir" \
    -Dtests=false \
    -Ddocs=false
  meson compile -C "$deps_dir/fribidi-$version/builddir"
  meson install -C "$deps_dir/fribidi-$version/builddir"
}

build_harfbuzz() {
  local version=11.5.0
  extract_tar_once "https://github.com/harfbuzz/harfbuzz/releases/download/$version/harfbuzz-$version.tar.xz" "harfbuzz-$version.tar.xz" "$deps_dir/harfbuzz-$version"
  meson_setup_static "$deps_dir/harfbuzz-$version" "$deps_dir/harfbuzz-$version/builddir" \
    -Dtests=disabled \
    -Ddocs=disabled \
    -Dglib=disabled \
    -Dgobject=disabled \
    -Dcairo=disabled \
    -Dicu=disabled \
    -Dfreetype=enabled
  meson compile -C "$deps_dir/harfbuzz-$version/builddir"
  meson install -C "$deps_dir/harfbuzz-$version/builddir"
}

build_libxml2() {
  [[ "$target_os" == "linux" ]] || return 0

  clone_or_update https://gitlab.gnome.org/GNOME/libxml2.git "$deps_dir/libxml2" "$libxml2_ref"
  meson_setup_static "$deps_dir/libxml2" "$deps_dir/libxml2/builddir" \
    -Ddocs=disabled \
    -Dicu=disabled \
    -Dmodules=disabled \
    -Dpython=disabled \
    -Dreadline=disabled \
    -Dzlib=enabled
  meson compile -C "$deps_dir/libxml2/builddir"
  meson install -C "$deps_dir/libxml2/builddir"
}

build_fontconfig() {
  [[ "$target_os" == "linux" ]] || return 0

  clone_or_update https://gitlab.freedesktop.org/fontconfig/fontconfig.git "$deps_dir/fontconfig" "$fontconfig_ref"
  meson_setup_static "$deps_dir/fontconfig" "$deps_dir/fontconfig/builddir" \
    -Dcache-build=disabled \
    -Ddoc=disabled \
    -Dfontations=disabled \
    -Dnls=disabled \
    -Dtests=disabled \
    -Dtools=disabled \
    -Dxml-backend=libxml2
  meson compile -C "$deps_dir/fontconfig/builddir"
  meson install -C "$deps_dir/fontconfig/builddir"
}

build_libass() {
  clone_or_update https://github.com/libass/libass.git "$deps_dir/libass" "$libass_ref"

  local fontconfig_option=disabled
  if [[ "$target_os" == "linux" ]]; then
    fontconfig_option=enabled
  fi

  meson_setup_static "$deps_dir/libass" "$deps_dir/libass/builddir" \
    -Dtest=disabled \
    -Dfontconfig="$fontconfig_option" \
    -Dlibunibreak=disabled
  meson compile -C "$deps_dir/libass/builddir"
  meson install -C "$deps_dir/libass/builddir"
}

build_libplacebo() {
  clone_or_update https://code.videolan.org/videolan/libplacebo.git "$deps_dir/libplacebo" "$libplacebo_ref" recursive
  local vulkan_option=disabled
  local vk_proc_addr_option=disabled
  local shaderc_option=disabled
  local vulkan_registry_arg=()
  if [[ "$target_os" == "linux" ]]; then
    vulkan_option=enabled
    vk_proc_addr_option=enabled
    shaderc_option=enabled
    vulkan_registry_arg=("-Dvulkan-registry=$prefix/share/vulkan/registry/vk.xml")
  fi

  meson_setup_static "$deps_dir/libplacebo" "$deps_dir/libplacebo/builddir" \
    -Ddemos=false \
    -Dtests=false \
    -Dopengl=enabled \
    -Dlcms=enabled \
    -Dunwind=disabled \
    -Dxxhash=disabled \
    -Dvulkan="$vulkan_option" \
    -Dvk-proc-addr="$vk_proc_addr_option" \
    -Dshaderc="$shaderc_option" \
    -Dglslang=disabled \
    "${vulkan_registry_arg[@]+"${vulkan_registry_arg[@]}"}"
  meson compile -C "$deps_dir/libplacebo/builddir"
  meson install -C "$deps_dir/libplacebo/builddir"
}

prepare_mpv_source() {
  clone_git_tag https://github.com/mpv-player/mpv.git "$mpv_ref" "$src_dir"
  cd "$src_dir"
  meson wrap update-db || true
  meson wrap install mujs || true
  meson subprojects download || true
}

build_mpv() {
  cd "$src_dir"
  local build_dir="$src_dir/build"
  local mpv_prefer_static=false
  if [[ "$target_os" == "linux" ]]; then
    mpv_prefer_static=false
  fi

  local args=(
    --prefix="$prefix"
    --libdir=lib
    --buildtype=release
    -Ddefault_library=shared
    -Dprefer_static="$mpv_prefer_static"
    -Doptimization=3
    -Db_ndebug=if-release
    -Dcplayer=false
    -Dlibmpv=true
    -Dgpl=true
    -Dlua=lua5.2
    -Djavascript=enabled
    -Diconv=enabled
    -Dlcms2=enabled
    -Dzlib=enabled
    -Dlibavdevice=enabled
    -Djpeg=disabled
    -Dlibarchive=disabled
    -Dlibbluray=disabled
    -Drubberband=enabled
    -Duchardet=enabled
    -Dzimg=enabled
    -Dshaderc=disabled
    -Dpdf-build=disabled
    -Dmanpage-build=disabled
    -Dhtml-build=disabled
    --force-fallback-for=mujs
    -Dmujs:werror=false
    -Dmujs:default_library=static
    "${meson_cross_args[@]+"${meson_cross_args[@]}"}"
  )

  if [[ "$target_os" == "linux" ]]; then
    local cuda_option=enabled
    local oss_audio_option=enabled
    if [[ "$target_arch" == "arm32" ]]; then
      cuda_option=disabled
      oss_audio_option=disabled
    fi

    args+=(
      -Dplain-gl=enabled
      "-Dc_link_args=-static-libgcc -static-libstdc++"
      "-Dcpp_link_args=-static-libgcc -static-libstdc++"
      -Dvulkan=enabled
      -Dcdda=disabled
      -Dcplugins=disabled
      -Ddvbin=disabled
      -Ddvdnav=disabled
      -Dvapoursynth=disabled
      -Dx11-clipboard=disabled
      -Dalsa=enabled
      -Djack=enabled
      -Doss-audio="$oss_audio_option"
      -Dpipewire=enabled
      -Dpulse=enabled
      -Dsndio=enabled
      -Dcaca=enabled
      -Ddmabuf-wayland=enabled
      -Ddrm=enabled
      -Degl=enabled
      -Degl-drm=enabled
      -Degl-wayland=enabled
      -Degl-x11=enabled
      -Dgbm=enabled
      -Dgl-x11=enabled
      -Dopenal=enabled
      -Dsdl2-audio=enabled
      -Dsdl2-gamepad=enabled
      -Dsdl2-video=enabled
      -Dsixel=enabled
      -Dvaapi=enabled
      -Dvaapi-drm=enabled
      -Dvaapi-wayland=enabled
      -Dvaapi-x11=enabled
      -Dvdpau=enabled
      -Dvdpau-gl-x11=enabled
      -Dwayland=enabled
      -Dx11=enabled
      -Dxv=enabled
      -Dcuda-hwaccel="$cuda_option"
      -Dcuda-interop="$cuda_option"
    )
  else
    args+=(
      -Dvulkan=disabled
      -Db_lto=true
      -Db_lto_mode=thin
    )
  fi

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

primary_mpv_library() {
  case "$target_os" in
    macos)
      find "$package_dir" -type f -name 'libmpv*.dylib' | sort -V | head -1
      ;;
    linux)
      find "$package_dir" -type f -name 'libmpv.so*' | sort -V | tail -1
      ;;
  esac
}

assert_static_mpv_deps() {
  local lib
  lib="$(primary_mpv_library)"
  [[ -n "$lib" ]] || die "could not find packaged libmpv for static dependency check"

  case "$target_os" in
    linux)
      need_cmd readelf
      local forbidden
      forbidden="$(
        readelf -d "$lib" |
          awk -F'[][]' '/NEEDED/ {print $2}' |
          grep -E '^(libav(codec|filter|format|util|device)|libsw(resample|scale)|libass|libplacebo|libmujs|liblua|liblcms2|libz|libdav1d|libfreetype|libfribidi|libharfbuzz|libfontconfig|libxml2|libpng|libunibreak|libunwind|libxxhash|libcdio|libdvd|libarchive|libbluray|librubberband|libuchardet|libzimg|libsixel|libdisplay-info|libshaderc|libSPIRV|libglslang|libjpeg|libstdc\+\+|libgcc_s)' || true
      )"
      [[ -z "$forbidden" ]] || die "libmpv still has dynamic third-party deps: $forbidden"
      ;;
    macos)
      need_cmd otool
      local forbidden
      forbidden="$(
        otool -L "$lib" |
          awk 'NR > 1 {print $1}' |
          grep -Ev '^(/usr/lib/|/System/Library/)' |
          grep -E '(/opt/homebrew|/usr/local|/Users/runner|libav(codec|filter|format|util|device)|libsw(resample|scale)|libass|libplacebo|libmujs|liblua|liblcms2|libz\.|libdav1d|libfreetype|libfribidi|libharfbuzz|libfontconfig|libxml2|libpng|libunibreak|libunwind|libxxhash|libcdio|libdvd|libarchive|libbluray|librubberband|libuchardet|libzimg|libshaderc|libSPIRV|libglslang|libjpeg)' || true
      )"
      [[ -z "$forbidden" ]] || die "libmpv still has dynamic third-party deps: $forbidden"
      ;;
  esac
}

fix_macos_install_names() {
  [[ "$target_os" == "macos" ]] || return 0

  local dylib
  while IFS= read -r dylib; do
    install_name_tool -id "@rpath/$(basename "$dylib")" "$dylib"
    codesign --force --sign - "$dylib" >/dev/null 2>&1 || true
  done < <(find "$package_dir" -type f -name 'libmpv*.dylib')
}

strip_packaged_mpv() {
  local lib

  case "$target_os" in
    linux)
      while IFS= read -r lib; do
        [[ -f "$lib" ]] || continue
        "$STRIP" --strip-unneeded "$lib" || "$STRIP" "$lib"
      done < <(find "$package_dir" -type f -name 'libmpv*.so*')
      ;;
    macos)
      while IFS= read -r lib; do
        [[ -f "$lib" ]] || continue
        "$STRIP" -x "$lib" || "$STRIP" "$lib"
      done < <(find "$package_dir" -type f -name 'libmpv*.dylib*')
      ;;
  esac
}

package_mpv() {
  case "$target_os" in
    macos)
      copy_matching_runtime_files "$prefix/lib" "libmpv dylibs" -name 'libmpv*.dylib*'
      strip_packaged_mpv
      fix_macos_install_names
      ;;
    linux)
      copy_matching_runtime_files "$prefix/lib" "libmpv shared libraries" -name 'libmpv*.so*'
      strip_packaged_mpv
      ;;
  esac

  require_mpv_runtime "$package_dir" "$target_os"
  assert_static_mpv_deps
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

need_cmd curl
need_cmd git
need_cmd meson
need_cmd ninja
need_cmd pkg-config
need_cmd tar
need_cmd zip

reset_dirs
setup_toolchain
write_meson_cross_file
set_cmake_args

build_zlib_ng
build_dav1d
build_lcms2
build_lua52
build_rubberband
build_uchardet
build_zimg
build_libsixel
build_libdisplay_info
build_nvcodec_headers
build_vulkan_headers
build_shaderc
build_libplacebo
build_ffmpeg
build_freetype
build_fribidi
build_harfbuzz
build_libxml2
build_fontconfig
build_libass
prepare_pc_static_zlib_runtime_for_mpv
prepare_pc_static_cxx_runtime_for_mpv
prepare_mpv_source
build_mpv
package_mpv
