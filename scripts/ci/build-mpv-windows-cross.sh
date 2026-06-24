#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

target_arch="${TARGET_ARCH:?TARGET_ARCH is required}"
mpv_ref="${MPV_REF:?MPV_REF is required}"

require_mpv_release_ref "$mpv_ref"

asset_name="libmpv-windows-$target_arch"
source_url="https://github.com/mpv-player/mpv.git#$mpv_ref"
src_dir="$WORK_DIR/mpv-windows-$target_arch"
prefix="$WORK_DIR/mpv-prefix-windows-$target_arch"
package_dir="$WORK_DIR/$asset_name"
deps_dir="$WORK_DIR/mpv-windows-deps-$target_arch"
download_cache="${DOWNLOAD_CACHE:-$WORK_DIR/downloads}"
llvm_mingw_version="${LLVM_MINGW_VERSION:-20260616}"
llvm_mingw_archive="llvm-mingw-$llvm_mingw_version-ucrt-ubuntu-22.04-x86_64.tar.xz"
llvm_mingw_url="https://github.com/mstorsjo/llvm-mingw/releases/download/$llvm_mingw_version/$llvm_mingw_archive"
llvm_mingw_root="$WORK_DIR/${llvm_mingw_archive%.tar.xz}"

assert_not_nightly_url "$source_url"
assert_not_nightly_url "$llvm_mingw_url"

case "$target_arch" in
  x86)
    mingw_target="i686-w64-mingw32"
    host_cpu_family="x86"
    host_cpu="i686"
    enable_vulkan=false
    enable_luajit=true
    ;;
  x64)
    mingw_target="x86_64-w64-mingw32"
    host_cpu_family="x86_64"
    host_cpu="x86_64"
    enable_vulkan=true
    enable_luajit=true
    ;;
  arm64)
    mingw_target="aarch64-w64-mingw32"
    host_cpu_family="aarch64"
    host_cpu="aarch64"
    enable_vulkan=true
    enable_luajit=false
    ;;
  *)
    die "unsupported Windows mpv arch: $target_arch"
    ;;
esac

unset TARGET_ARCH

install_deps() {
  if [[ "${SKIP_APT_INSTALL:-false}" == "true" ]]; then
    return
  fi

  sudo apt-get update
  sudo apt-get install -y --no-install-recommends \
    autoconf automake autopoint build-essential ca-certificates ccache cmake curl git \
    gcc-multilib g++-multilib libtool m4 make nasm ninja-build pkg-config python3 \
    python3-pip tar unzip wget xz-utils zip

  install_pip_meson 1.6.1
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

  local archive="$WORK_DIR/$archive_name"
  rm -f "$archive"
  download_tar "$url" "$archive"
  tar -C "$WORK_DIR" -xf "$archive"
  [[ -d "$expected_dir" ]] || die "expected $archive_name to extract to $expected_dir"
}

clone_or_update() {
  local repo_url="$1"
  local dest="$2"
  local extra="${3:-}"

  if [[ -d "$dest/.git" ]]; then
    return
  fi

  if [[ "$extra" == "recursive" ]]; then
    git clone --depth 1 --recursive --shallow-submodules "$repo_url" "$dest"
  else
    git clone --depth 1 "$repo_url" "$dest"
  fi
}

setup_toolchain() {
  extract_tar_once "$llvm_mingw_url" "$llvm_mingw_archive" "$llvm_mingw_root"
  export PATH="$llvm_mingw_root/bin:$PATH"

  need_cmd "$mingw_target-clang"
  need_cmd "$mingw_target-clang++"
  need_cmd "$mingw_target-ar"
  need_cmd "$mingw_target-ranlib"
  need_cmd "$mingw_target-windres"
}

reset_dirs() {
  rm -rf "$src_dir" "$prefix" "$package_dir" "$deps_dir"
  mkdir -p "$prefix" "$package_dir" "$deps_dir" "$download_cache"
}

write_cross_file() {
  cross_file="$WORK_DIR/meson-cross-windows-$target_arch.txt"
  cat >"$cross_file" <<EOF
[built-in options]
buildtype = 'release'
wrap_mode = 'default'
default_library = 'shared'

[binaries]
c = ['ccache', '$mingw_target-clang']
cpp = ['ccache', '$mingw_target-clang++']
ar = '$mingw_target-ar'
strip = '$mingw_target-strip'
pkgconfig = 'pkg-config'
pkg-config = 'pkg-config'
windres = '$mingw_target-windres'
dlltool = '$mingw_target-dlltool'
nasm = 'nasm'

[host_machine]
system = 'windows'
cpu_family = '$host_cpu_family'
cpu = '$host_cpu'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOF
}

setup_env() {
  export CC="ccache $mingw_target-clang"
  export CXX="ccache $mingw_target-clang++"
  export AR="$mingw_target-ar"
  export NM="$mingw_target-nm"
  export RANLIB="$mingw_target-ranlib"
  export STRIP="$mingw_target-strip"
  export WINDRES="$mingw_target-windres"
  unset PKG_CONFIG_SYSROOT_DIR
  export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig:$prefix/share/pkgconfig"
  export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
  export CFLAGS="-O2 -pipe -I$prefix/include"
  export CXXFLAGS="$CFLAGS"
  export LDFLAGS="-L$prefix/lib"
}

cmake_common_args=()
set_cmake_args() {
  cmake_common_args=(
    -Wno-dev
    -GNinja
    -DCMAKE_SYSTEM_NAME=Windows
    -DCMAKE_SYSTEM_PROCESSOR="$host_cpu_family"
    -DCMAKE_C_COMPILER="$llvm_mingw_root/bin/$mingw_target-clang"
    -DCMAKE_CXX_COMPILER="$llvm_mingw_root/bin/$mingw_target-clang++"
    -DCMAKE_RC_COMPILER="$llvm_mingw_root/bin/$mingw_target-windres"
    -DCMAKE_AR="$llvm_mingw_root/bin/$mingw_target-ar"
    -DCMAKE_RANLIB="$llvm_mingw_root/bin/$mingw_target-ranlib"
    -DCMAKE_FIND_ROOT_PATH="$prefix"
    -DCMAKE_INSTALL_PREFIX="$prefix"
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=ON
  )
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
    make -j"$(nproc)"
    make install
  fi
}

build_iconv() {
  local version=1.18
  extract_tar_once "https://ftpmirror.gnu.org/gnu/libiconv/libiconv-$version.tar.gz" "libiconv-$version.tar.gz" "$WORK_DIR/libiconv-$version"
  builddir "$WORK_DIR/libiconv-$version"
  ../configure --host="$mingw_target" --prefix="$prefix" --disable-static --enable-shared
  install_build
}

build_zlib_ng() {
  local version=2.2.5
  extract_tar_once "https://github.com/zlib-ng/zlib-ng/archive/refs/tags/$version.tar.gz" "zlib-ng-$version.tar.gz" "$WORK_DIR/zlib-ng-$version"
  builddir "$WORK_DIR/zlib-ng-$version"
  cmake .. "${cmake_common_args[@]}" -DZLIB_COMPAT=ON -DBUILD_TESTING=OFF
  install_build
  ln -snf libzlib.dll.a "$prefix/lib/libz.dll.a"
}

build_dav1d() {
  clone_or_update https://code.videolan.org/videolan/dav1d.git "$deps_dir/dav1d"
  builddir "$deps_dir/dav1d"
  meson setup .. --cross-file "$cross_file" --prefix "$prefix" -Denable_tools=false -Denable_tests=false
  install_build
}

build_lcms2() {
  clone_or_update https://github.com/mm2/Little-CMS.git "$deps_dir/lcms2"
  builddir "$deps_dir/lcms2"
  meson setup .. --cross-file "$cross_file" --prefix "$prefix" -Dtests=disabled -Dutils=false -Dversionedlibs=false
  install_build
}

build_amf_headers() {
  local version=1.5.2
  extract_tar_once "https://github.com/GPUOpen-LibrariesAndSDKs/AMF/releases/download/v$version/AMF-headers-v$version.tar.gz" "AMF-headers-v$version.tar.gz" "$WORK_DIR/amf-headers-v$version"
  mkdir -p "$prefix/include"
  cp -a "$WORK_DIR/amf-headers-v$version/AMF" "$prefix/include/"
}

build_vulkan_headers() {
  clone_or_update https://github.com/KhronosGroup/Vulkan-Headers.git "$deps_dir/Vulkan-Headers"
  builddir "$deps_dir/Vulkan-Headers"
  cmake .. "${cmake_common_args[@]}"
  install_build
}

build_vulkan_loader() {
  clone_or_update https://github.com/KhronosGroup/Vulkan-Loader.git "$deps_dir/Vulkan-Loader" recursive
  builddir "$deps_dir/Vulkan-Loader"
  cmake .. "${cmake_common_args[@]}" -DUSE_GAS=ON -DBUILD_TESTS=OFF
  install_build
}

build_shaderc() {
  if [[ ! -d "$deps_dir/shaderc/.git" ]]; then
    git clone --depth 1 https://github.com/google/shaderc.git "$deps_dir/shaderc"
    (cd "$deps_dir/shaderc" && ./utils/git-sync-deps)
  fi
  builddir "$deps_dir/shaderc"
  cmake .. "${cmake_common_args[@]}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DSHADERC_SKIP_TESTS=ON \
    -DSHADERC_SKIP_EXAMPLES=ON
  install_build
}

build_spirv_cross() {
  clone_or_update https://github.com/KhronosGroup/SPIRV-Cross.git "$deps_dir/SPIRV-Cross"
  builddir "$deps_dir/SPIRV-Cross"
  cmake .. "${cmake_common_args[@]}" -DSPIRV_CROSS_SHARED=ON -DSPIRV_CROSS_CLI=OFF -DSPIRV_CROSS_STATIC=OFF
  install_build
}

build_ffmpeg() {
  clone_or_update https://github.com/FFmpeg/FFmpeg.git "$deps_dir/ffmpeg"
  builddir "$deps_dir/ffmpeg"

  local args=(
    --prefix="$prefix"
    --pkg-config=pkg-config
    --target-os=mingw32
    --arch="$host_cpu"
    --enable-cross-compile
    --cross-prefix="$mingw_target-"
    --cc="$CC"
    --cxx="$CXX"
    --ar="$AR"
    --ranlib="$RANLIB"
    --strip="$STRIP"
    --disable-static
    --enable-shared
    --disable-doc
    --disable-programs
    --enable-gpl
    --enable-muxer=spdif
    --enable-encoder=mjpeg,png
    --enable-libdav1d
  )

  if "$enable_vulkan" && pkg-config --exists vulkan shaderc; then
    args+=(--enable-vulkan --enable-libshaderc)
  fi

  ../configure "${args[@]}"
  install_build
}

build_libplacebo() {
  clone_or_update https://code.videolan.org/videolan/libplacebo.git "$deps_dir/libplacebo" recursive
  builddir "$deps_dir/libplacebo"

  local args=(
    --cross-file "$cross_file"
    --prefix "$prefix"
    -Ddemos=false
    -Dopengl=enabled
    -Dd3d11=enabled
    -Dlcms=enabled
  )

  if "$enable_vulkan"; then
    args+=(-Dvulkan=enabled "-Dvulkan-registry=$prefix/share/vulkan/registry/vk.xml")
  else
    args+=(-Dvulkan=disabled)
  fi

  meson setup .. "${args[@]}"
  install_build
}

build_freetype() {
  local version=2.14.1
  extract_tar_once "https://download.savannah.gnu.org/releases/freetype/freetype-$version.tar.xz" "freetype-$version.tar.xz" "$WORK_DIR/freetype-$version"
  builddir "$WORK_DIR/freetype-$version"
  meson setup .. --cross-file "$cross_file" --prefix "$prefix"
  install_build
}

build_fribidi() {
  local version=1.0.16
  extract_tar_once "https://github.com/fribidi/fribidi/releases/download/v$version/fribidi-$version.tar.xz" "fribidi-$version.tar.xz" "$WORK_DIR/fribidi-$version"
  builddir "$WORK_DIR/fribidi-$version"
  meson setup .. --cross-file "$cross_file" --prefix "$prefix" -Dtests=false -Ddocs=false
  install_build
}

build_harfbuzz() {
  local version=11.5.0
  extract_tar_once "https://github.com/harfbuzz/harfbuzz/releases/download/$version/harfbuzz-$version.tar.xz" "harfbuzz-$version.tar.xz" "$WORK_DIR/harfbuzz-$version"
  builddir "$WORK_DIR/harfbuzz-$version"
  meson setup .. --cross-file "$cross_file" --prefix "$prefix" -Dtests=disabled
  install_build
}

build_libass() {
  clone_or_update https://github.com/libass/libass.git "$deps_dir/libass"
  builddir "$deps_dir/libass"
  meson setup .. --cross-file "$cross_file" --prefix "$prefix"
  install_build
}

build_luajit() {
  "$enable_luajit" || return 0

  clone_or_update https://github.com/LuaJIT/LuaJIT.git "$deps_dir/LuaJIT"
  cd "$deps_dir/LuaJIT"

  local hostcc="ccache cc"
  local flags=()
  if [[ "$target_arch" == "x86" ]]; then
    hostcc="$hostcc -m32"
    flags+=(XCFLAGS=-DLUAJIT_NO_UNWIND)
  fi

  make TARGET_SYS=Windows clean
  make TARGET_SYS=Windows CC=clang HOST_CC="$hostcc" CROSS="$mingw_target-" BUILDMODE=static "${flags[@]}" amalg
  make TARGET_SYS=Windows CC=clang HOST_CC="$hostcc" CROSS="$mingw_target-" \
    PREFIX="$prefix" INSTALL_DEP= FILE_T=luajit.exe install
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
  local lua_option=disabled
  local vulkan_option=disabled

  if "$enable_luajit"; then
    lua_option=luajit
  fi
  if "$enable_vulkan"; then
    vulkan_option=enabled
  fi

  local args=(
    --cross-file "$cross_file"
    --prefix "$prefix"
    --buildtype=release
    -Ddefault_library=shared
    -Dcplayer=false
    -Dlibmpv=true
    -Dgpl=true
    -Dlua="$lua_option"
    -Djavascript=enabled
    -Diconv=enabled
    -Dlcms2=enabled
    -Dzlib=enabled
    -Dd3d11=enabled
    -Dshaderc=enabled
    -Dspirv-cross=enabled
    -Dvulkan="$vulkan_option"
    -Djpeg=disabled
    -Dlibarchive=disabled
    -Dlibbluray=disabled
    -Ddvdnav=disabled
    -Drubberband=disabled
    -Duchardet=disabled
    -Dzimg=disabled
    -Dpdf-build=disabled
    -Dmanpage-build=disabled
    -Dhtml-build=disabled
  )

  meson setup "$build_dir" "${args[@]}"
  meson compile -C "$build_dir"
}

copy_runtime_dlls() {
  local build_dir="$src_dir/build"
  local dll

  mkdir -p "$package_dir"
  while IFS= read -r dll; do
    cp -a "$dll" "$package_dir/"
  done < <(find "$build_dir" "$prefix/bin" -maxdepth 1 -type f -iname '*.dll' 2>/dev/null | sort)

  for dll in \
    "$llvm_mingw_root/$mingw_target/bin/"*.dll \
    "$llvm_mingw_root/bin/"*.dll; do
    [[ -f "$dll" ]] || continue
    cp -n "$dll" "$package_dir/"
  done

  require_mpv_runtime "$package_dir" windows
  zip_package "$package_dir" "$asset_name"
}

need_cmd curl
need_cmd git
need_cmd tar
need_cmd zip

install_deps
setup_toolchain
reset_dirs
write_cross_file
setup_env
set_cmake_args

build_iconv
build_zlib_ng
build_dav1d
build_lcms2
build_amf_headers
if "$enable_vulkan"; then
  build_vulkan_headers
  build_vulkan_loader
fi
build_shaderc
build_spirv_cross
build_ffmpeg
build_libplacebo
build_freetype
build_fribidi
build_harfbuzz
build_libass
build_luajit
prepare_mpv_source
build_mpv
copy_runtime_dlls
