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
libass_ref="${LIBASS_REF:-0.17.5}"
libplacebo_ref="${LIBPLACEBO_REF:-v6.338.2}"
vulkan_sdk_ref="${VULKAN_SDK_REF:-vulkan-sdk-1.4.350.1}"
vulkan_headers_ref="${VULKAN_HEADERS_REF:-$vulkan_sdk_ref}"
vulkan_loader_ref="${VULKAN_LOADER_REF:-$vulkan_sdk_ref}"
spirv_cross_ref="${SPIRV_CROSS_REF:-$vulkan_sdk_ref}"
shaderc_ref="${SHADERC_REF:-v2026.2}"
luajit_ref="${LUAJIT_REF:-v2.1.0-beta3}"
rubberband_ref="${RUBBERBAND_REF:-v4.0.0}"
uchardet_ref="${UCHARDET_REF:-v0.0.8}"
zimg_ref="${ZIMG_REF:-release-3.0.6}"

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
c_args = ['-O2', '-pipe', '-I$prefix/include']
cpp_args = ['-O2', '-pipe', '-I$prefix/include']
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
  export CFLAGS="-O2 -pipe -I$prefix/include"
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

build_amf_headers() {
  local version=1.5.2
  extract_tar_once "https://github.com/GPUOpen-LibrariesAndSDKs/AMF/releases/download/v$version/AMF-headers-v$version.tar.gz" "AMF-headers-v$version.tar.gz" "$WORK_DIR/amf-headers-v$version"
  mkdir -p "$prefix/include"
  cp -a "$WORK_DIR/amf-headers-v$version/AMF" "$prefix/include/"
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
    --enable-gpl
    --enable-zlib
    --enable-libzimg
    --enable-muxer=spdif
    --enable-encoder=mjpeg,png
    --enable-libdav1d
    --extra-cflags="$CFLAGS"
    --extra-ldflags="$LDFLAGS"
  )

  if "$enable_vulkan" && pkg-config --exists vulkan shaderc; then
    args+=(--enable-vulkan --enable-libshaderc)
  fi

  ../configure "${args[@]}"
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
    -Drubberband=enabled
    -Duchardet=enabled
    -Dzimg=enabled
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
      grep -E '(avcodec|avfilter|avformat|avutil|swresample|swscale|ass|placebo|lua|luajit|mujs|lcms|zlib|png|dav1d|freetype|fribidi|harfbuzz|rubberband|uchardet|zimg|unwind|xxhash|shaderc|spirv|vulkan-1|iconv|winpthread|libgcc|libstdc)' || true
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
build_dav1d
build_lcms2
build_zimg
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
build_lua52
build_rubberband
build_uchardet
prepare_mpv_source
build_mpv
package_mpv_dll
