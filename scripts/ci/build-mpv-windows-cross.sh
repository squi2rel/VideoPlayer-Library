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
ffmpeg_ref="${FFMPEG_REF:-n7.1.2}"
dav1d_ref="${DAV1D_REF:-1.5.3}"
lcms2_ref="${LCMS2_REF:-lcms2.19.1}"
mbedtls_version="${MBEDTLS_VERSION:-3.6.6}"
libass_ref="${LIBASS_REF:-0.17.5}"
libplacebo_ref="${LIBPLACEBO_REF:-v6.338.2}"
nvcodec_ref="${NVCODEC_REF:-n13.0.19.0}"
vulkan_sdk_ref="${VULKAN_SDK_REF:-vulkan-sdk-1.4.350.1}"
vulkan_headers_ref="${VULKAN_HEADERS_REF:-$vulkan_sdk_ref}"
vulkan_loader_ref="${VULKAN_LOADER_REF:-$vulkan_sdk_ref}"
spirv_cross_ref="${SPIRV_CROSS_REF:-$vulkan_sdk_ref}"
shaderc_ref="${SHADERC_REF:-v2026.2}"
luajit_ref="${LUAJIT_REF:-v2.1.0-beta3}"
rubberband_ref="${RUBBERBAND_REF:-v4.0.0}"
uchardet_ref="${UCHARDET_REF:-v0.0.8}"
zimg_ref="${ZIMG_REF:-release-3.0.6}"
libwebp_ref="${LIBWEBP_REF:-v1.6.0}"
soxr_ref="${SOXR_REF:-0.1.3}"
libmysofa_ref="${LIBMYSOFA_REF:-v1.3.4}"
libarchive_ref="${LIBARCHIVE_REF:-v3.8.8}"
libsrt_ref="${LIBSRT_REF:-v1.5.5}"
openal_soft_ref="${OPENAL_SOFT_REF:-openal-soft-1.21.0}"
libopenmpt_version="${LIBOPENMPT_VERSION:-0.7.12}"

assert_not_nightly_url "$source_url"
assert_not_nightly_url "$llvm_mingw_url"

case "$target_arch" in
  x86)
    mingw_target="i686-w64-mingw32"
    host_cpu_family="x86"
    host_cpu="i686"
    enable_vulkan=true
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
  if [[ "${SKIP_APT_INSTALL:-false}" != "true" ]]; then
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends \
      autoconf automake autopoint build-essential ca-certificates ccache cmake curl git \
      gcc-multilib g++-multilib libtool m4 make nasm ninja-build pkg-config python3 \
      python3-pip tar unzip wget xz-utils zip
  fi

  install_pip_meson 1.6.1
  install_pip_package glad2
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
  local ref="${3:-}"
  local extra="${4:-}"

  if [[ -d "$dest/.git" ]]; then
    return
  fi

  local args=(--depth 1)
  [[ -z "$ref" ]] || args+=(--branch "$ref")
  if [[ "$extra" == "recursive" ]]; then
    args+=(--recursive --shallow-submodules)
  fi
  git_clone_retry "${args[@]}" "$repo_url" "$dest"
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
default_library = 'static'
prefer_static = true
b_lto = true
b_lto_mode = 'thin'
optimization = '3'
c_args = ['-O3', '-pipe', '-I$prefix/include']
cpp_args = ['-O3', '-pipe', '-I$prefix/include']
c_link_args = ['-L$prefix/lib', '-static', '-static-libgcc', '-static-libstdc++']
cpp_link_args = ['-L$prefix/lib', '-static', '-static-libgcc', '-static-libstdc++']

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
pkg_config_libdir = ['$prefix/lib/pkgconfig', '$prefix/share/pkgconfig']
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
  export CFLAGS="-O3 -pipe -I$prefix/include"
  export CXXFLAGS="$CFLAGS"
  export LDFLAGS="-L$prefix/lib -static -static-libgcc -static-libstdc++"
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
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
    -DCMAKE_INSTALL_PREFIX="$prefix"
    -DCMAKE_INSTALL_LIBDIR=lib
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=OFF
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    -DCMAKE_C_FLAGS="$CFLAGS"
    -DCMAKE_CXX_FLAGS="$CXXFLAGS"
    -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS"
    -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS"
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
  ../configure --host="$mingw_target" --prefix="$prefix" --enable-static --disable-shared
  install_build

  mkdir -p "$prefix/lib/pkgconfig"
  cat >"$prefix/lib/pkgconfig/iconv.pc" <<EOF
prefix=$prefix
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: iconv
Description: GNU character set conversion library
Version: $version
Libs: -L\${libdir} -liconv
Cflags: -I\${includedir}
EOF
}

build_zlib_ng() {
  local version=2.2.5
  extract_tar_once "https://github.com/zlib-ng/zlib-ng/archive/refs/tags/$version.tar.gz" "zlib-ng-$version.tar.gz" "$WORK_DIR/zlib-ng-$version"
  builddir "$WORK_DIR/zlib-ng-$version"
  cmake .. "${cmake_common_args[@]}" -DZLIB_COMPAT=ON -DZLIB_ENABLE_TESTS=OFF -DZLIBNG_ENABLE_TESTS=OFF -DBUILD_TESTING=OFF
  install_build
}

build_mbedtls() {
  extract_tar_once "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$mbedtls_version/mbedtls-$mbedtls_version.tar.bz2" \
    "mbedtls-$mbedtls_version.tar.bz2" \
    "$WORK_DIR/mbedtls-$mbedtls_version"
  builddir "$WORK_DIR/mbedtls-$mbedtls_version"
  cmake .. "${cmake_common_args[@]}" \
    -DENABLE_PROGRAMS=OFF \
    -DENABLE_TESTING=OFF \
    -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
    -DUSE_STATIC_MBEDTLS_LIBRARY=ON
  install_build

  mkdir -p "$prefix/lib/pkgconfig"
  if [[ ! -f "$prefix/lib/pkgconfig/mbedtls.pc" ]]; then
    cat >"$prefix/lib/pkgconfig/mbedtls.pc" <<EOF
prefix=$prefix
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: mbedTLS
Description: mbed TLS SSL/TLS library
Version: $mbedtls_version
Libs: -L\${libdir} -lmbedtls -lmbedx509 -lmbedcrypto -lws2_32 -lbcrypt
Cflags: -I\${includedir}
EOF
  fi

  append_pc_private_libs "$prefix/lib/pkgconfig/mbedtls.pc" -lws2_32 -lbcrypt
  [[ ! -f "$prefix/lib/pkgconfig/mbedx509.pc" ]] || append_pc_private_libs "$prefix/lib/pkgconfig/mbedx509.pc" -lws2_32
  [[ ! -f "$prefix/lib/pkgconfig/mbedcrypto.pc" ]] || append_pc_private_libs "$prefix/lib/pkgconfig/mbedcrypto.pc" -lbcrypt

  pkg-config --exists mbedtls || die "mbedtls pkg-config metadata is not visible"
  local test_c="$WORK_DIR/mbedtls-pkg-config-test-$target_arch.c"
  local test_exe="$WORK_DIR/mbedtls-pkg-config-test-$target_arch.exe"
  printf '#include <mbedtls/ssl.h>\n#include <mbedtls/x509_crt.h>\nint main(void) { mbedtls_ssl_context ssl; mbedtls_x509_crt crt; mbedtls_ssl_init(&ssl); mbedtls_x509_crt_init(&crt); return 0; }\n' >"$test_c"
  "$mingw_target-clang" $CFLAGS $(pkg-config --cflags mbedtls) "$test_c" -o "$test_exe" $LDFLAGS $(pkg-config --libs --static mbedtls) ||
    die "mbedtls pkg-config static link test failed"
  rm -f "$test_c" "$test_exe"
}

build_dav1d() {
  clone_or_update https://code.videolan.org/videolan/dav1d.git "$deps_dir/dav1d" "$dav1d_ref"
  builddir "$deps_dir/dav1d"
  meson setup .. --cross-file "$cross_file" --prefix "$prefix" --libdir lib -Denable_tools=false -Denable_tests=false
  install_build
}

build_lcms2() {
  clone_or_update https://github.com/mm2/Little-CMS.git "$deps_dir/lcms2" "$lcms2_ref"
  builddir "$deps_dir/lcms2"
  meson setup .. --cross-file "$cross_file" --prefix "$prefix" --libdir lib -Dtests=disabled -Dutils=false -Dversionedlibs=false
  install_build
}

build_libwebp() {
  clone_or_update https://chromium.googlesource.com/webm/libwebp.git "$deps_dir/libwebp" "$libwebp_ref"
  builddir "$deps_dir/libwebp"
  cmake .. "${cmake_common_args[@]}" \
    -DWEBP_BUILD_ANIM_UTILS=OFF \
    -DWEBP_BUILD_CWEBP=OFF \
    -DWEBP_BUILD_DWEBP=OFF \
    -DWEBP_BUILD_EXTRAS=OFF \
    -DWEBP_BUILD_GIF2WEBP=OFF \
    -DWEBP_BUILD_IMG2WEBP=OFF \
    -DWEBP_BUILD_VWEBP=OFF \
    -DWEBP_BUILD_WEBPINFO=OFF \
    -DWEBP_BUILD_WEBPMUX=OFF \
    -DWEBP_ENABLE_SIMD=ON
  install_build
}

ensure_soxr_pkg_config() {
  local version="${soxr_ref#v}"
  local pc_dir="$prefix/lib/pkgconfig"
  local pc_file="$pc_dir/soxr.pc"
  local lsr_pc_file="$pc_dir/soxr-lsr.pc"

  mkdir -p "$pc_dir"
  [[ -f "$prefix/lib/libsoxr.a" ]] || die "soxr static library was not installed: $prefix/lib/libsoxr.a"
  if [[ ! -f "$pc_file" ]]; then
    cat >"$pc_file" <<EOF
Name: soxr
Description: High quality, one-dimensional sample-rate conversion library
Version: $version
Libs: -L$prefix/lib -lsoxr
Cflags: -I$prefix/include
EOF
  fi

  if [[ -f "$prefix/lib/libsoxr-lsr.a" && ! -f "$lsr_pc_file" ]]; then
    cat >"$lsr_pc_file" <<EOF
Name: soxr-lsr
Description: High quality, one-dimensional sample-rate conversion library (with libsamplerate-like bindings)
Version: $version
Libs: -L$prefix/lib -lsoxr-lsr
Cflags: -I$prefix/include
EOF
  fi

  if grep -q '^Libs\.private:' "$pc_file"; then
    sed -i.bak -E 's|^Libs\.private:.*|Libs.private: -lm|' "$pc_file"
  else
    printf 'Libs.private: -lm\n' >>"$pc_file"
  fi
  rm -f "$pc_file.bak"
}

build_libsoxr() {
  clone_or_update https://github.com/chirlu/soxr.git "$deps_dir/soxr" "$soxr_ref"
  builddir "$deps_dir/soxr"
  cmake .. "${cmake_common_args[@]}" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTS=OFF \
    -DWITH_OPENMP=OFF \
    -DHAVE_WORDS_BIGENDIAN_EXITCODE=1
  install_build

  ensure_soxr_pkg_config
}

build_libmysofa() {
  clone_or_update https://github.com/hoene/libmysofa.git "$deps_dir/libmysofa" "$libmysofa_ref"
  builddir "$deps_dir/libmysofa"
  cmake .. "${cmake_common_args[@]}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTS=OFF \
    -DBUILD_TESTING=OFF
  install_build
}

build_libarchive() {
  clone_or_update https://github.com/libarchive/libarchive.git "$deps_dir/libarchive" "$libarchive_ref"
  builddir "$deps_dir/libarchive"
  cmake .. "${cmake_common_args[@]}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_TEST=OFF \
    -DBUILD_TESTING=OFF \
    -DENABLE_CPIO=OFF \
    -DENABLE_CAT=OFF \
    -DENABLE_TAR=OFF \
    -DENABLE_WERROR=OFF \
    -DENABLE_ZLIB=ON \
    -DENABLE_ICONV=ON \
    -DENABLE_OPENSSL=OFF \
    -DENABLE_MBEDTLS=OFF \
    -DENABLE_NETTLE=OFF \
    -DENABLE_BZip2=OFF \
    -DENABLE_LIBB2=OFF \
    -DENABLE_EXPAT=OFF \
    -DENABLE_LIBXML2=OFF \
    -DENABLE_LZMA=OFF \
    -DENABLE_LZO=OFF \
    -DENABLE_LZ4=OFF \
    -DENABLE_ZSTD=OFF \
    -DENABLE_PCREPOSIX=OFF \
    -DENABLE_CNG=OFF \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  install_build
}

build_libopenmpt() {
  local archive_name="libopenmpt-$libopenmpt_version+release.autotools.tar.gz"
  local source_dir="$WORK_DIR/libopenmpt-$libopenmpt_version+release.autotools"
  extract_tar_once "https://lib.openmpt.org/files/libopenmpt/src/$archive_name" "$archive_name" "$source_dir"
  cd "$source_dir"
  make distclean >/dev/null 2>&1 || true
  ./configure \
    --host="$mingw_target" \
    --prefix="$prefix" \
    --enable-static \
    --disable-shared \
    --disable-openmpt123 \
    --disable-examples \
    --disable-tests \
    --disable-doxygen-doc \
    --disable-doxygen-html \
    --without-mpg123 \
    --without-flac \
    --without-ogg \
    --without-vorbis \
    --without-vorbisfile \
    --without-sndfile
  install_build

  local pc_file="$prefix/lib/pkgconfig/libopenmpt.pc"
  [[ -f "$pc_file" ]] || die "libopenmpt pkg-config file was not installed: $pc_file"
  if grep -q '^Libs\.private:' "$pc_file"; then
    sed -i.bak -E 's|^Libs\.private:.*|Libs.private: -lz -lc++ -lc++abi -lunwind -lm|' "$pc_file"
  else
    printf 'Libs.private: -lz -lc++ -lc++abi -lunwind -lm\n' >>"$pc_file"
  fi
  rm -f "$pc_file.bak"
}

append_pc_private_libs() {
  local pc_file="$1"
  shift
  local current="Libs.private:"
  local updated
  local lib
  local tmp_file="$pc_file.tmp"

  if grep -q '^Libs\.private:' "$pc_file"; then
    current="$(grep -m1 '^Libs\.private:' "$pc_file")"
    current="${current/Libs.private:/Libs.private: }"
  fi

  updated="$current"
  for lib in "$@"; do
    if [[ " $updated " != *" $lib "* ]]; then
      updated+=" $lib"
    fi
  done

  awk -v updated="$updated" '
    BEGIN { replaced = 0 }
    /^Libs\.private:/ && !replaced {
      print updated
      replaced = 1
      next
    }
    { print }
    END {
      if (!replaced) {
        print updated
      }
    }
  ' "$pc_file" >"$tmp_file"
  mv "$tmp_file" "$pc_file"
}

append_pc_cflags() {
  local pc_file="$1"
  shift
  local current="Cflags:"
  local updated
  local flag
  local tmp_file="$pc_file.tmp"

  if grep -q '^Cflags:' "$pc_file"; then
    current="$(grep -m1 '^Cflags:' "$pc_file")"
    current="${current/Cflags:/Cflags: }"
  fi

  updated="$current"
  for flag in "$@"; do
    if [[ " $updated " != *" $flag "* ]]; then
      updated+=" $flag"
    fi
  done

  awk -v updated="$updated" '
    BEGIN { replaced = 0 }
    /^Cflags:/ && !replaced {
      print updated
      replaced = 1
      next
    }
    { print }
    END {
      if (!replaced) {
        print updated
      }
    }
  ' "$pc_file" >"$tmp_file"
  mv "$tmp_file" "$pc_file"
}

ensure_libsrt_pkg_config() {
  local pc_dir="$prefix/lib/pkgconfig"
  local pc_file
  local test_c="$WORK_DIR/srt-pkg-config-test-$target_arch.c"
  local test_exe="$WORK_DIR/srt-pkg-config-test-$target_arch.exe"
  local required_private_libs=(
    -pthread
  )

  mkdir -p "$pc_dir"
  [[ -f "$prefix/lib/libsrt.a" ]] || die "srt static library was not installed: $prefix/lib/libsrt.a"
  [[ -f "$pc_dir/srt.pc" ]] || die "srt pkg-config file was not installed: $pc_dir/srt.pc"

  for pc_file in "$pc_dir/srt.pc" "$pc_dir/haisrt.pc"; do
    [[ -f "$pc_file" ]] || continue
    append_pc_private_libs "$pc_file" "${required_private_libs[@]}"
  done

  pkg-config --exists "srt >= 1.3.0" || die "srt pkg-config metadata is not visible"
  printf '#include <srt/srt.h>\nint main(void) { return srt_startup(); }\n' >"$test_c"
  "$mingw_target-clang" $CFLAGS "$test_c" -o "$test_exe" $LDFLAGS $(pkg-config --cflags --libs --static srt) ||
    die "srt pkg-config static link test failed"
  rm -f "$test_c" "$test_exe"
}

build_libsrt() {
  clone_or_update https://github.com/Haivision/srt.git "$deps_dir/srt" "$libsrt_ref"
  builddir "$deps_dir/srt"
  cmake .. "${cmake_common_args[@]}" \
    -DCMAKE_PREFIX_PATH="$prefix" \
    -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_APPS=OFF \
    -DENABLE_CXX11=ON \
    -DENABLE_SHARED=OFF \
    -DSTATIC_MBEDTLS=ON \
    -DUSE_ENCLIB=mbedtls \
    -DMBEDTLS_PREFIX="$prefix" \
    -DMBEDTLS_INCLUDE_DIR="$prefix/include" \
    -DMBEDTLS_LIBRARY="$prefix/lib/libmbedtls.a" \
    -DMBEDX509_LIBRARY="$prefix/lib/libmbedx509.a" \
    -DMBEDCRYPTO_LIBRARY="$prefix/lib/libmbedcrypto.a" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  install_build

  ensure_libsrt_pkg_config
}

build_openal_soft() {
  clone_or_update https://github.com/kcat/openal-soft.git "$deps_dir/openal-soft" "$openal_soft_ref"
  builddir "$deps_dir/openal-soft"
  cmake .. "${cmake_common_args[@]}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DLIBTYPE=STATIC \
    -DALSOFT_UTILS=OFF \
    -DALSOFT_EXAMPLES=OFF \
    -DALSOFT_TESTS=OFF \
    -DALSOFT_INSTALL_CONFIG=OFF \
    -DALSOFT_INSTALL_HRTF_DATA=OFF \
    -DALSOFT_BACKEND_PIPEWIRE=OFF \
    -DCMAKE_C_FLAGS="$CFLAGS -include stdlib.h" \
    -DCMAKE_CXX_FLAGS="$CXXFLAGS -include cstdlib"
  install_build

  local pc_file="$prefix/lib/pkgconfig/openal.pc"
  [[ -f "$pc_file" ]] || die "OpenAL pkg-config file was not installed: $pc_file"
  append_pc_cflags "$pc_file" -DAL_LIBTYPE_STATIC
  append_pc_private_libs "$pc_file" -lwinmm -lole32 -luuid -lshlwapi -lc++ -lc++abi -lunwind

  pkg-config --exists "openal >= 1.1" || die "OpenAL pkg-config metadata is not visible"
  local test_c="$WORK_DIR/openal-pkg-config-test-$target_arch.c"
  local test_exe="$WORK_DIR/openal-pkg-config-test-$target_arch.exe"
  printf '#include <AL/al.h>\nint main(void) { return (int)alGetError(); }\n' >"$test_c"
  "$mingw_target-clang" $CFLAGS $(pkg-config --cflags openal) "$test_c" -o "$test_exe" $LDFLAGS $(pkg-config --libs --static openal) ||
    die "OpenAL pkg-config static link test failed"
  rm -f "$test_c" "$test_exe"
}

build_amf_headers() {
  local version=1.5.2
  extract_tar_once "https://github.com/GPUOpen-LibrariesAndSDKs/AMF/releases/download/v$version/AMF-headers-v$version.tar.gz" "AMF-headers-v$version.tar.gz" "$WORK_DIR/amf-headers-v$version"
  mkdir -p "$prefix/include"
  cp -a "$WORK_DIR/amf-headers-v$version/AMF" "$prefix/include/"
}

build_nvcodec_headers() {
  clone_or_update https://github.com/FFmpeg/nv-codec-headers.git "$deps_dir/nv-codec-headers" "$nvcodec_ref"
  make -C "$deps_dir/nv-codec-headers" PREFIX="$prefix" install
}

build_vulkan_headers() {
  clone_or_update https://github.com/KhronosGroup/Vulkan-Headers.git "$deps_dir/Vulkan-Headers" "$vulkan_headers_ref"
  builddir "$deps_dir/Vulkan-Headers"
  cmake .. "${cmake_common_args[@]}"
  install_build
}

patch_vulkan_loader_static() {
  python3 - "$deps_dir/Vulkan-Loader" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])

def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    if old not in text:
        raise SystemExit(f"expected Vulkan loader hook not found in {path}: {old!r}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")

def replace_first_of(path: Path, replacements: list[tuple[str, str]]) -> None:
    text = path.read_text(encoding="utf-8")
    for old, new in replacements:
        if old in text:
            path.write_text(text.replace(old, new, 1), encoding="utf-8")
            return
    expected = " or ".join(repr(old) for old, _ in replacements)
    raise SystemExit(f"expected Vulkan loader hook not found in {path}: {expected}")

cmake = root / "loader" / "CMakeLists.txt"
replace_once(
    cmake,
    "target_include_directories(loader_specific_options INTERFACE ${CMAKE_CURRENT_SOURCE_DIR} ${CMAKE_CURRENT_SOURCE_DIR}/generated ${CMAKE_CURRENT_BINARY_DIR})\n",
    "target_include_directories(loader_specific_options INTERFACE ${CMAKE_CURRENT_SOURCE_DIR} ${CMAKE_CURRENT_SOURCE_DIR}/generated ${CMAKE_CURRENT_BINARY_DIR})\nconfigure_file(\"vulkan_own.pc.in\" \"vulkan_own.pc\" @ONLY)\n",
)
replace_once(cmake, "if(WIN32)\n\n    if(ENABLE_WIN10_ONECORE)", "if(WIN32 AND NOT MINGW)\n\n    if(ENABLE_WIN10_ONECORE)")
replace_once(cmake, "if(WIN32)\n    # If BUILD_DLL_VERSIONINFO", "if(MSVC)\n    # If BUILD_DLL_VERSIONINFO")
replace_once(
    cmake,
    """else()
    if(APPLE)
        option(APPLE_STATIC_LOADER "Build a loader that can be statically linked. Intended for Chromium usage/testing.")
        mark_as_advanced(APPLE_STATIC_LOADER)
    endif()

    if(APPLE_STATIC_LOADER)
        add_library(vulkan STATIC)
        target_compile_definitions(vulkan PRIVATE APPLE_STATIC_LOADER)

        message(WARNING "The APPLE_STATIC_LOADER option has been set. Note that this will only work on MacOS and is not supported "
                "or tested as part of the loader. Use it at your own risk.")
    else()
        add_library(vulkan SHARED)
    endif()

    target_sources(vulkan PRIVATE ${NORMAL_LOADER_SRCS})
""",
    """else()
    add_library(vulkan STATIC)
    target_compile_definitions(vulkan PRIVATE BUILD_STATIC_LOADER)
    target_sources(vulkan PRIVATE ${NORMAL_LOADER_SRCS})
""",
)
replace_once(cmake, "if (APPLE_STATIC_LOADER)\n", "if (BUILD_STATIC_LOADER)\n")

loader_c = root / "loader" / "loader.c"
replace_once(loader_c, "#if defined(_WIN32)\nBOOL __stdcall loader_initialize", "#if defined(LOADER_DYNAMIC_LIB)\nBOOL __stdcall loader_initialize")
replace_once(loader_c, "#if defined(_WIN32)\n    return TRUE;", "#if defined(LOADER_DYNAMIC_LIB)\n    return TRUE;")

loader_h = root / "loader" / "loader.h"
replace_once(
    loader_h,
    "// Declare the once_init variable\nLOADER_PLATFORM_THREAD_ONCE_EXTERN_DEFINITION(once_init)\n",
    "// Declare the once_init variable\n#if defined(_WIN32) && !defined(LOADER_DYNAMIC_LIB)\nLOADER_PLATFORM_THREAD_ONCE_EXTERN_DEFINITION(once_init)\n#endif\n",
)
replace_once(loader_h, "#if defined(_WIN32)\nBOOL __stdcall loader_initialize", "#if defined(LOADER_DYNAMIC_LIB)\nBOOL __stdcall loader_initialize")

loader_rc = root / "loader" / "loader.rc.in"
replace_once(loader_rc, '#include "winres.h"\n', '#ifdef __MINGW64__\n#include <winresrc.h>\n#else\n#include "winres.h"\n#endif\n')

loader_windows = root / "loader" / "loader_windows.c"
replace_once(loader_windows, "\nBOOL WINAPI DllMain(", "\n#if defined(LOADER_DYNAMIC_LIB)\nBOOL WINAPI DllMain(")
replace_first_of(
    loader_windows,
    [
        ("    return TRUE;\n}\n\nVkResult windows_add_json_entry", "    return TRUE;\n}\n#endif\n\nVkResult windows_add_json_entry"),
        ("    return TRUE;\n}\n\nbool windows_add_json_entry", "    return TRUE;\n}\n#endif\n\nbool windows_add_json_entry"),
    ],
)

platform = root / "loader" / "vk_loader_platform.h"
replace_once(platform, '#include <direct.h>\n\n#include "stack_allocation.h"', '#include <direct.h>\n#include <pthread.h>\n\n#include "stack_allocation.h"')
replace_once(
    platform,
    """#if defined(APPLE_STATIC_LOADER) && !defined(__APPLE__)
#error "APPLE_STATIC_LOADER can only be defined on Apple platforms!"
#endif

#if defined(APPLE_STATIC_LOADER)
""",
    "#if defined(BUILD_STATIC_LOADER)\n",
)
replace_once(platform, "#if defined(APPLE_STATIC_LOADER)\nstatic inline void loader_platform_thread_once_fn", "#if defined(BUILD_STATIC_LOADER)\nstatic inline void loader_platform_thread_once_fn")
replace_once(platform, "#elif defined(WIN32)\nstatic inline void loader_platform_thread_win32_once_fn", "#elif defined(LOADER_DYNAMIC_LIB)\nstatic inline void loader_platform_thread_win32_once_fn")

(root / "loader" / "vulkan_own.pc.in").write_text("""prefix=@CMAKE_INSTALL_PREFIX@
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: Vulkan-Loader
Description: Vulkan Loader
Version: @VULKAN_LOADER_VERSION@
Libs: -L${libdir} -lvulkan
Libs.private: -lshlwapi -lcfgmgr32
Cflags: -I${includedir}
""", encoding="utf-8")
PY
}

build_vulkan_loader() {
  clone_or_update https://github.com/KhronosGroup/Vulkan-Loader.git "$deps_dir/Vulkan-Loader" "$vulkan_loader_ref" recursive
  patch_vulkan_loader_static
  builddir "$deps_dir/Vulkan-Loader"
  cmake .. "${cmake_common_args[@]}" \
    -DUSE_GAS=ON \
    -DBUILD_TESTS=OFF \
    -DENABLE_WERROR=OFF \
    -DBUILD_STATIC_LOADER=ON \
    -DCMAKE_C_FLAGS="$CFLAGS -D__STDC_FORMAT_MACROS -DSTRSAFE_NO_DEPRECATE -Dparse_number=cjson_parse_number" \
    -DCMAKE_CXX_FLAGS="$CXXFLAGS -D__STDC_FORMAT_MACROS -fpermissive"
  ninja

  mkdir -p "$prefix/lib/pkgconfig"
  install -m 0644 loader/libvulkan.a "$prefix/lib/libvulkan.a"
  install -m 0644 loader/vulkan_own.pc "$prefix/lib/pkgconfig/vulkan.pc"
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
  if [[ ! -d "$deps_dir/shaderc/.git" ]]; then
    git_clone_retry --depth 1 --branch "$shaderc_ref" https://github.com/google/shaderc.git "$deps_dir/shaderc"
  fi
  sync_shaderc_deps
  python3 - "$deps_dir/shaderc/libshaderc/CMakeLists.txt" <<'PY'
from pathlib import Path
path = Path(__import__("sys").argv[1])
text = path.read_text(encoding="utf-8")
old = "add_library(shaderc_shared SHARED"
new = "add_library(shaderc_shared STATIC"
if old not in text and new not in text:
    raise SystemExit("shaderc shared-library CMake hook changed")
text = text.replace(old, new)
path.write_text(text, encoding="utf-8")
PY
  python3 - "$deps_dir/shaderc/third_party/spirv-tools/source/CMakeLists.txt" <<'PY'
from pathlib import Path
path = Path(__import__("sys").argv[1])
text = path.read_text(encoding="utf-8")
old = "add_library(${SPIRV_TOOLS}-shared SHARED"
new = "add_library(${SPIRV_TOOLS}-shared STATIC"
if old not in text and new not in text:
    raise SystemExit("SPIRV-Tools shared-library CMake hook changed")
text = text.replace(old, new)
path.write_text(text, encoding="utf-8")
PY
  builddir "$deps_dir/shaderc"
  cmake .. "${cmake_common_args[@]}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DSHADERC_SKIP_TESTS=ON \
    -DSHADERC_SKIP_EXAMPLES=ON \
    -DSHADERC_SKIP_EXECUTABLES=ON \
    -DSHADERC_SKIP_COPYRIGHT_CHECK=ON
  install_build

  local pc_file
  for pc_file in "$prefix/lib/pkgconfig/shaderc.pc" "$prefix/lib/pkgconfig/shaderc_static.pc"; do
    [[ -f "$pc_file" ]] || die "shaderc pkg-config file was not installed: $pc_file"
    sed -i.bak -E "s|^Libs:.*|Libs: -L\${libdir} -lshaderc_combined -lc++ -lc++abi -lunwind|" "$pc_file"
    rm -f "$pc_file.bak"
  done
}

build_spirv_cross() {
  clone_or_update https://github.com/KhronosGroup/SPIRV-Cross.git "$deps_dir/SPIRV-Cross" "$spirv_cross_ref"
  builddir "$deps_dir/SPIRV-Cross"
  cmake .. "${cmake_common_args[@]}" -DSPIRV_CROSS_SHARED=OFF -DSPIRV_CROSS_CLI=OFF -DSPIRV_CROSS_STATIC=ON
  install_build

  if [[ -f "$prefix/lib/pkgconfig/spirv-cross-c.pc" && ! -f "$prefix/lib/pkgconfig/spirv-cross-c-shared.pc" ]]; then
    cp "$prefix/lib/pkgconfig/spirv-cross-c.pc" "$prefix/lib/pkgconfig/spirv-cross-c-shared.pc"
  fi

  local pc_file
  local spirv_cross_libs="-lspirv-cross-c -lspirv-cross-glsl -lspirv-cross-hlsl -lspirv-cross-msl -lspirv-cross-cpp -lspirv-cross-reflect -lspirv-cross-util -lspirv-cross-core -lc++ -lc++abi -lunwind"
  for pc_file in "$prefix/lib/pkgconfig/spirv-cross-c.pc" "$prefix/lib/pkgconfig/spirv-cross-c-shared.pc"; do
    [[ -f "$pc_file" ]] || die "SPIRV-Cross pkg-config file was not installed: $pc_file"
    sed -i.bak -E "s|^Libs:.*|Libs: -L\${libdir} $spirv_cross_libs|" "$pc_file"
    rm -f "$pc_file.bak"
  done
}

build_ffmpeg() {
  clone_or_update https://github.com/FFmpeg/FFmpeg.git "$deps_dir/ffmpeg" "$ffmpeg_ref"
  builddir "$deps_dir/ffmpeg"

  local args=(
    --prefix="$prefix"
    --pkg-config=pkg-config
    --pkg-config-flags=--static
    --target-os=mingw32
    --arch="$host_cpu"
    --enable-cross-compile
    --cross-prefix="$mingw_target-"
    --cc="$CC"
    --cxx="$CXX"
    --ar="$AR"
    --ranlib="$RANLIB"
    --strip="$STRIP"
    --enable-static
    --disable-shared
    --disable-doc
    --disable-programs
    --enable-runtime-cpudetect
    --enable-lto=thin
    --enable-gpl
    --enable-version3
    --enable-zlib
    --enable-mbedtls
    --enable-lcms2
    --enable-libass
    --enable-libzimg
    --enable-libwebp
    --enable-libsoxr
    --enable-libmysofa
    --enable-libopenmpt
    --enable-libsrt
    --enable-muxer=spdif
    --enable-encoder=mjpeg,png
    --enable-libdav1d
    --enable-libfreetype
    --enable-libfribidi
    --enable-libharfbuzz
    --enable-amf
    --enable-openal
    --enable-libplacebo
    --extra-cflags="$CFLAGS -DAL_LIBTYPE_STATIC"
    --extra-ldflags="$LDFLAGS"
    --extra-libs="-lc++ -lc++abi -lunwind -lws2_32 -lbcrypt -lwinmm -lole32 -luuid -lshlwapi"
  )

  if [[ "$target_arch" != arm64 ]]; then
    args+=(--enable-ffnvcodec)
  fi

  if "$enable_vulkan" && pkg-config --exists vulkan shaderc; then
    args+=(--enable-vulkan --enable-libshaderc)
  fi

  if ! ../configure "${args[@]}"; then
    print_ffmpeg_config_log
    return 1
  fi
  install_build
}

build_libplacebo() {
  clone_or_update https://code.videolan.org/videolan/libplacebo.git "$deps_dir/libplacebo" "$libplacebo_ref" recursive
  builddir "$deps_dir/libplacebo"

  local args=(
    --cross-file "$cross_file"
    --prefix "$prefix"
    --libdir lib
    -Ddemos=false
    -Dopengl=enabled
    -Dd3d11=enabled
    -Dlcms=enabled
    -Dunwind=disabled
    -Dxxhash=disabled
  )

  if "$enable_vulkan"; then
    args+=(-Dvulkan=enabled -Dvk-proc-addr=enabled "-Dvulkan-registry=$prefix/share/vulkan/registry/vk.xml")
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
  meson setup .. --cross-file "$cross_file" --prefix "$prefix" --libdir lib
  install_build
}

build_fribidi() {
  local version=1.0.16
  extract_tar_once "https://github.com/fribidi/fribidi/releases/download/v$version/fribidi-$version.tar.xz" "fribidi-$version.tar.xz" "$WORK_DIR/fribidi-$version"
  builddir "$WORK_DIR/fribidi-$version"
  meson setup .. --cross-file "$cross_file" --prefix "$prefix" --libdir lib -Dtests=false -Ddocs=false
  install_build
}

build_harfbuzz() {
  local version=11.5.0
  extract_tar_once "https://github.com/harfbuzz/harfbuzz/releases/download/$version/harfbuzz-$version.tar.xz" "harfbuzz-$version.tar.xz" "$WORK_DIR/harfbuzz-$version"
  builddir "$WORK_DIR/harfbuzz-$version"
  meson setup .. --cross-file "$cross_file" --prefix "$prefix" --libdir lib -Dtests=disabled
  install_build
}

build_libass() {
  clone_or_update https://github.com/libass/libass.git "$deps_dir/libass" "$libass_ref"
  builddir "$deps_dir/libass"
  meson setup .. --cross-file "$cross_file" --prefix "$prefix" --libdir lib
  install_build
}

build_luajit() {
  "$enable_luajit" || return 0

  clone_or_update https://github.com/LuaJIT/LuaJIT.git "$deps_dir/LuaJIT" "$luajit_ref"
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

  local pc_file="$prefix/lib/pkgconfig/luajit.pc"
  [[ -f "$pc_file" ]] || die "LuaJIT pkg-config file was not installed: $pc_file"
  sed -i.bak -E 's/^Libs\.private:.*/Libs.private: -lm/' "$pc_file"
  rm -f "$pc_file.bak"
}

build_lua52() {
  "$enable_luajit" && return 0

  local version=5.2.4
  extract_tar_once "https://www.lua.org/ftp/lua-$version.tar.gz" "lua-$version.tar.gz" "$WORK_DIR/lua-$version"
  cd "$WORK_DIR/lua-$version"

  make -C src clean || true
  make -C src a \
    CC="$CC" \
    AR="$AR rcu" \
    RANLIB="$RANLIB" \
    MYCFLAGS="$CFLAGS -DLUA_COMPAT_ALL -DLUA_USE_WINDOWS" \
    MYLDFLAGS="$LDFLAGS"

  mkdir -p "$prefix/include" "$prefix/lib" "$prefix/lib/pkgconfig"
  install -m 0644 src/liblua.a "$prefix/lib/"
  install -m 0644 src/lua.h src/luaconf.h src/lualib.h src/lauxlib.h src/lua.hpp "$prefix/include/"

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
  cp "$prefix/lib/pkgconfig/lua5.2.pc" "$prefix/lib/pkgconfig/lua52.pc"
}

build_rubberband() {
  clone_or_update https://github.com/breakfastquay/rubberband.git "$deps_dir/rubberband" "$rubberband_ref"
  builddir "$deps_dir/rubberband"
  meson setup .. \
    --cross-file "$cross_file" \
    --prefix "$prefix" \
    --libdir lib \
    -Ddefault_library=static \
    -Dprefer_static=true \
    -Dfft=builtin \
    -Dresampler=builtin \
    -Djni=disabled \
    -Dladspa=disabled \
    -Dlv2=disabled \
    -Dvamp=disabled \
    -Dcmdline=disabled \
    -Dtests=disabled
  install_build

  local pc_file="$prefix/lib/pkgconfig/rubberband.pc"
  [[ -f "$pc_file" ]] || die "rubberband pkg-config file was not installed: $pc_file"
  if ! grep -q '^Libs\.private:' "$pc_file"; then
    printf 'Libs.private: -lc++ -lc++abi -lunwind -lm\n' >>"$pc_file"
  fi
}

build_uchardet() {
  clone_or_update https://gitlab.freedesktop.org/uchardet/uchardet.git "$deps_dir/uchardet" "$uchardet_ref"
  builddir "$deps_dir/uchardet"
  cmake .. "${cmake_common_args[@]}" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_BINARY=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DTARGET_ARCHITECTURE="$host_cpu_family"
  install_build
}

build_zimg() {
  clone_or_update https://github.com/sekrit-twc/zimg.git "$deps_dir/zimg" "$zimg_ref"
  cd "$deps_dir/zimg"
  sed -i.bak 's/<Windows.h>/<windows.h>/g' src/zimg/common/arm/cpuinfo_arm.cpp
  rm -f src/zimg/common/arm/cpuinfo_arm.cpp.bak
  ./autogen.sh
  make distclean >/dev/null 2>&1 || true
  STL_LIBS="-lc++ -lc++abi -lunwind" ./configure \
    --host="$mingw_target" \
    --prefix="$prefix" \
    --libdir="$prefix/lib" \
    --enable-static \
    --disable-shared \
    --disable-dependency-tracking \
    --disable-testapp \
    --disable-example \
    --disable-unit-test
  install_build
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
  else
    lua_option=lua5.2
  fi
  if "$enable_vulkan"; then
    vulkan_option=enabled
  fi

  local args=(
    --cross-file "$cross_file"
    --prefix "$prefix"
    --libdir lib
    --buildtype=release
    -Ddefault_library=shared
    -Dprefer_static=true
    -Doptimization=3
    -Db_ndebug=if-release
    -Db_lto=true
    -Db_lto_mode=thin
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
    -Dlibarchive=enabled
    -Dlibbluray=disabled
    -Ddvdnav=disabled
    -Drubberband=enabled
    -Duchardet=enabled
    -Dzimg=enabled
    -Dopenal=enabled
    -Dpdf-build=disabled
    -Dmanpage-build=disabled
    -Dhtml-build=disabled
    --force-fallback-for=mujs,iconv
    -Dmujs:werror=false
    -Dmujs:default_library=static
    -Dwin-iconv:default_library=static
  )

  meson setup "$build_dir" "${args[@]}"
  meson compile -C "$build_dir"
}

assert_static_mpv_dll_deps() {
  local dll="$1"
  local objdump="$llvm_mingw_root/bin/llvm-objdump"
  [[ -x "$objdump" ]] || objdump="$llvm_mingw_root/bin/$mingw_target-objdump"
  [[ -x "$objdump" ]] || die "missing objdump for Windows DLL dependency check"

  local forbidden
  forbidden="$(
    "$objdump" -p "$dll" |
      awk '/DLL Name:/ {print tolower($3)}' |
      grep -E '(avcodec|avfilter|avformat|avutil|avdevice|swresample|swscale|ass|placebo|lua|luajit|mujs|lcms|zlib|png|dav1d|freetype|fribidi|harfbuzz|rubberband|uchardet|zimg|webp|soxr|mysofa|openmpt|archive|srt|mbed|openal|unwind|xxhash|shaderc|spirv|vulkan-1|iconv|winpthread|libgcc|libstdc)' || true
  )"
  [[ -z "$forbidden" ]] || die "libmpv still imports dynamic third-party DLLs: $forbidden"
}

package_mpv_dll() {
  local build_dir="$src_dir/build"
  local dll
  local copied=0

  mkdir -p "$package_dir"
  while IFS= read -r dll; do
    cp -a "$dll" "$package_dir/"
    "$STRIP" --strip-unneeded "$package_dir/$(basename "$dll")" || "$STRIP" "$package_dir/$(basename "$dll")"
    assert_static_mpv_dll_deps "$package_dir/$(basename "$dll")"
    copied=1
  done < <(find "$build_dir" "$prefix/bin" -maxdepth 1 -type f \( -iname 'libmpv*.dll' -o -iname 'mpv-*.dll' \) 2>/dev/null | sort)

  [[ "$copied" -eq 1 ]] || die "could not find libmpv DLL under $build_dir or $prefix/bin"
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
build_mbedtls
build_dav1d
build_lcms2
build_zimg
build_libwebp
build_libsoxr
build_libmysofa
build_libarchive
build_libopenmpt
build_libsrt
build_openal_soft
build_amf_headers
  if [[ "$target_arch" != arm64 ]]; then
    build_nvcodec_headers
  fi
if "$enable_vulkan"; then
  build_vulkan_headers
  build_vulkan_loader
fi
build_shaderc
build_spirv_cross
build_libplacebo
build_freetype
build_fribidi
build_harfbuzz
build_libass
build_rubberband
build_uchardet
build_ffmpeg
build_luajit
build_lua52
prepare_mpv_source
build_mpv
package_mpv_dll
