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
  if [[ "${SKIP_APT_INSTALL:-false}" != "true" ]]; then
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends \
      autoconf automake autopoint bash build-essential ca-certificates cmake curl gettext git \
      libtool nasm ninja-build openjdk-17-jdk pkg-config python3 python3-pip unzip yasm zip
  fi

  install_pip_meson 1.6.1
}

patch_mpv_android_static_linking() {
  python3 - "$src_dir" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])

def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    if old not in text:
        raise SystemExit(f"expected build hook not found in {path}: {old!r}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")

def write_executable(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)

ffmpeg = root / "buildscripts" / "scripts" / "ffmpeg.sh"
replace_once(
    ffmpeg,
    "--cross-prefix=$ndk_triple- --cc=$CC --pkg-config=pkg-config --nm=llvm-nm",
    "--cross-prefix=$ndk_triple- --cc=$CC --ar=$AR --ranlib=$RANLIB --strip=llvm-strip --pkg-config=pkg-config --pkg-config-flags=--static --nm=llvm-nm",
)
replace_once(
    ffmpeg,
    '--extra-cflags="-I$prefix_dir/include $cpuflags" --extra-ldflags="-L$prefix_dir/lib"',
    '--extra-cflags="-O3 -pipe -I$prefix_dir/include $cpuflags" --extra-ldflags="-L$prefix_dir/lib"',
)
replace_once(
    ffmpeg,
    "--disable-static --enable-shared --enable-{gpl,version3}",
    "--enable-static --disable-shared --enable-pic --enable-{gpl,version3}",
)
replace_once(
    ffmpeg,
    "--disable-{stripping,doc,programs}",
    "--enable-runtime-cpudetect --enable-lto=thin\n\t--disable-{stripping,doc,programs}",
)

mpv = root / "buildscripts" / "scripts" / "mpv.sh"
replace_once(
    mpv,
    "--default-library shared \\\n",
    "--default-library shared -Dprefer_static=true -Doptimization=3 -Db_ndebug=if-release -Db_lto=true -Db_lto_mode=thin \\\n",
)
replace_once(
    mpv,
    "unset CC CXX # meson wants these unset\n\n",
    r'''unset CC CXX # meson wants these unset

python3 - "$prefix_dir" <<'ICONV_PY'
from pathlib import Path
import sys

prefix = sys.argv[1]
path = Path("meson.build")
text = path.read_text(encoding="utf-8")
old = "iconv = dependency('iconv', required: get_option('iconv'))"
new = (
    "iconv_lib = cc.find_library('iconv', dirs: '%s/lib', required: get_option('iconv'))\n"
    "if iconv_lib.found()\n"
    "    iconv = declare_dependency(dependencies: iconv_lib, compile_args: ['-I%s/include'])\n"
    "else\n"
    "    iconv = iconv_lib\n"
    "endif"
) % (prefix, prefix)
if old in text:
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
elif "iconv_lib = cc.find_library('iconv'" not in text:
    raise SystemExit("mpv iconv dependency hook changed")
ICONV_PY

''',
)

buildall = root / "buildscripts" / "buildall.sh"
replace_once(
    buildall,
    'export LDFLAGS="-Wl,-O1,--icf=safe -Wl,-z,max-page-size=16384"',
    'export CFLAGS="-O3 -pipe"\n\texport CXXFLAGS="-O3 -pipe"\n\texport LDFLAGS="-Wl,-O1,--icf=safe -Wl,-z,max-page-size=16384 -static-libstdc++"',
)
replace_once(
    buildall,
    "prefix = '/usr/local'\n[binaries]\n",
    "prefix = '/usr/local'\noptimization = '3'\nb_ndebug = 'if-release'\nc_args = ['-O3', '-pipe', '-I$prefix_dir/include']\ncpp_args = ['-O3', '-pipe', '-I$prefix_dir/include']\nc_link_args = ['-L$prefix_dir/lib', '-Wl,-O1,--icf=safe', '-Wl,-z,max-page-size=16384', '-static-libstdc++']\ncpp_link_args = ['-L$prefix_dir/lib', '-Wl,-O1,--icf=safe', '-Wl,-z,max-page-size=16384', '-static-libstdc++']\n[binaries]\n",
)

mpv = root / "buildscripts" / "scripts" / "mpv.sh"
replace_once(
    mpv,
    "-Diconv=disabled -Dlua=enabled \\\n",
    "-Diconv=enabled -Dlua=enabled \\\n\t-Drubberband=enabled -Duchardet=enabled -Dzimg=enabled \\\n",
)

depinfo = root / "buildscripts" / "include" / "depinfo.sh"
replace_once(
    depinfo,
    "v_fontconfig=2.17.1\n",
    "v_fontconfig=2.17.1\nv_libiconv=1.18\nv_rubberband=4.0.0\nv_uchardet=0.0.8\nv_zimg=3.0.6\n",
)
replace_once(
    depinfo,
    "dep_libplacebo=()\ndep_mpv=(ffmpeg libass lua libplacebo)\n",
    "dep_libplacebo=()\ndep_libiconv=()\ndep_rubberband=()\ndep_uchardet=(libiconv)\ndep_zimg=()\ndep_mpv=(ffmpeg libass lua libplacebo libiconv rubberband uchardet zimg)\n",
)
replace_once(
    depinfo,
    'ci_tarball="prefix-ndk-${v_ndk}-lua-${v_lua}-unibreak-${v_unibreak}-harfbuzz-${v_harfbuzz}-fribidi-${v_fribidi}-freetype-${v_freetype}-libxml2-${v_libxml2}-fontconfig-${v_fontconfig}-mbedtls-${v_mbedtls}-ffmpeg-${v_ci_ffmpeg}.tgz"',
    'ci_tarball="prefix-ndk-${v_ndk}-lua-${v_lua}-unibreak-${v_unibreak}-harfbuzz-${v_harfbuzz}-fribidi-${v_fribidi}-freetype-${v_freetype}-libxml2-${v_libxml2}-fontconfig-${v_fontconfig}-mbedtls-${v_mbedtls}-ffmpeg-${v_ci_ffmpeg}-libiconv-${v_libiconv}-rubberband-${v_rubberband}-uchardet-${v_uchardet}-zimg-${v_zimg}.tgz"',
)

download_deps = root / "buildscripts" / "include" / "download-deps.sh"
replace_once(
    download_deps,
    "# mpv\n[ ! -d mpv ] && git clone https://github.com/mpv-player/mpv\n",
    """# libiconv
if [ ! -d libiconv ]; then
\tmkdir libiconv
\t$WGET https://ftp.gnu.org/pub/gnu/libiconv/libiconv-$v_libiconv.tar.gz -O - | \\
\t\ttar -xz -C libiconv --strip-components=1
fi

# rubberband
if [ ! -d rubberband ]; then
\tmkdir rubberband
\t$WGET https://github.com/breakfastquay/rubberband/archive/refs/tags/v$v_rubberband.tar.gz -O - | \\
\t\ttar -xz -C rubberband --strip-components=1
fi

# uchardet
if [ ! -d uchardet ]; then
\tmkdir uchardet
\t$WGET https://gitlab.freedesktop.org/uchardet/uchardet/-/archive/v$v_uchardet/uchardet-v$v_uchardet.tar.gz -O - | \\
\t\ttar -xz -C uchardet --strip-components=1
fi

# zimg
if [ ! -d zimg ]; then
\tmkdir zimg
\t$WGET https://github.com/sekrit-twc/zimg/archive/refs/tags/release-$v_zimg.tar.gz -O - | \\
\t\ttar -xz -C zimg --strip-components=1
fi

# mpv
[ ! -d mpv ] && git clone https://github.com/mpv-player/mpv
""",
)

scripts = root / "buildscripts" / "scripts"
write_executable(scripts / "libiconv.sh", r'''#!/bin/bash -e

. ../../include/path.sh
. ../../include/depinfo.sh

if [ "$1" == "build" ]; then
	true
elif [ "$1" == "clean" ]; then
	make distclean >/dev/null 2>&1 || true
	exit 0
else
	exit 255
fi

make distclean >/dev/null 2>&1 || true

./configure \
	--host=$ndk_triple \
	--prefix=/usr/local \
	--with-pic \
	--enable-static \
	--disable-shared \
	--disable-nls \
	--disable-rpath

make -j$cores
make DESTDIR="$prefix_dir" install

mkdir -p "$prefix_dir/lib/pkgconfig"
cat >"$prefix_dir/lib/pkgconfig/iconv.pc" <<EOF
prefix=/usr/local
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: iconv
Description: GNU libiconv
Version: $v_libiconv
Libs: -L\${libdir} -liconv
Cflags: -I\${includedir}
EOF
''')

write_executable(scripts / "rubberband.sh", r'''#!/bin/bash -e

. ../../include/path.sh

build=_build$ndk_suffix

if [ "$1" == "build" ]; then
	true
elif [ "$1" == "clean" ]; then
	rm -rf $build
	exit 0
else
	exit 255
fi

unset CC CXX

meson setup $build --cross-file "$prefix_dir"/crossfile.txt \
	-Ddefault_library=static -Dprefer_static=true \
	-Dfft=builtin -Dresampler=builtin \
	-Djni=disabled -Dladspa=disabled -Dlv2=disabled -Dvamp=disabled \
	-Dcmdline=disabled -Dtests=disabled

ninja -C $build -j$cores
DESTDIR="$prefix_dir" ninja -C $build install

pc="$prefix_dir/lib/pkgconfig/rubberband.pc"
if [ -f "$pc" ] && ! grep -q '^Libs\.private:' "$pc"; then
	printf 'Libs.private: -lc++ -lm\n' >>"$pc"
fi
''')

write_executable(scripts / "uchardet.sh", r'''#!/bin/bash -e

. ../../include/path.sh
. ../../include/depinfo.sh

build=_build$ndk_suffix

if [ "$1" == "build" ]; then
	true
elif [ "$1" == "clean" ]; then
	rm -rf $build
	exit 0
else
	exit 255
fi

case "$ndk_triple" in
	arm-linux-androideabi) android_abi=armeabi-v7a ;;
	aarch64-linux-android) android_abi=arm64-v8a ;;
	i686-linux-android) android_abi=x86 ;;
	x86_64-linux-android) android_abi=x86_64 ;;
	*) echo "unknown Android target: $ndk_triple" >&2; exit 1 ;;
esac

cmake -S . -B $build -G Ninja \
	-DCMAKE_TOOLCHAIN_FILE="$DIR/sdk/android-ndk-${v_ndk}/build/cmake/android.toolchain.cmake" \
	-DANDROID_ABI="$android_abi" \
	-DANDROID_PLATFORM=android-21 \
	-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
	-DCMAKE_INSTALL_PREFIX=/usr/local \
	-DCMAKE_INSTALL_LIBDIR=lib \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
	-DBUILD_SHARED_LIBS=OFF \
	-DBUILD_BINARY=OFF

ninja -C $build -j$cores
DESTDIR="$prefix_dir" ninja -C $build install

pc="$prefix_dir/lib/pkgconfig/uchardet.pc"
if [ -f "$pc" ] && ! grep -q '^Libs\.private:' "$pc"; then
	printf 'Libs.private: -lc++\n' >>"$pc"
fi
''')

write_executable(scripts / "zimg.sh", r'''#!/bin/bash -e

. ../../include/path.sh

if [ "$1" == "build" ]; then
	true
elif [ "$1" == "clean" ]; then
	make distclean >/dev/null 2>&1 || true
	exit 0
else
	exit 255
fi

[ -f configure ] || ./autogen.sh
make distclean >/dev/null 2>&1 || true

STL_LIBS="-lc++ -lm" ./configure \
	--host=$ndk_triple \
	--prefix=/usr/local \
	--with-pic \
	--enable-static \
	--disable-shared \
	--disable-dependency-tracking \
	--disable-testapp \
	--disable-example \
	--disable-unit-test

make -j$cores
make DESTDIR="$prefix_dir" install

pc="$prefix_dir/lib/pkgconfig/zimg.pc"
if [ -f "$pc" ] && ! grep -q '^Libs\.private:' "$pc"; then
	printf 'Libs.private: -lc++ -lm\n' >>"$pc"
fi
''')
PY
}

collect_mpv_so() {
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
      done < <(find "$dir" -type f -name 'libmpv.so')
    fi
  done

  if [[ "$copied" -eq 0 ]]; then
    while IFS= read -r so; do
      cp -f "$so" "$package_dir/"
      copied=1
    done < <(find "$src_dir" -type f -name 'libmpv.so')
  fi

  [[ "$copied" -eq 1 ]] || die "mpv-android build produced no libmpv.so"
}

strip_android_mpv() {
  local lib="$package_dir/libmpv.so"
  [[ -f "$lib" ]] || die "could not find packaged Android libmpv.so to strip"

  local strip_bin=""
  local search_root
  for search_root in \
    "$src_dir/buildscripts/sdk" \
    "${ANDROID_NDK_HOME:-}" \
    "${ANDROID_NDK_ROOT:-}" \
    "${ANDROID_HOME:-}"; do
    [[ -n "$search_root" && -d "$search_root" ]] || continue
    strip_bin="$(find -L "$search_root" -type f -path '*/toolchains/llvm/prebuilt/*/bin/llvm-strip' -print -quit 2>/dev/null || true)"
    [[ -n "$strip_bin" ]] && break
  done
  if [[ -z "$strip_bin" ]]; then
    strip_bin="$(command -v llvm-strip || true)"
  fi
  [[ -n "$strip_bin" ]] || die "could not find Android llvm-strip"

  "$strip_bin" --strip-unneeded "$lib" || "$strip_bin" "$lib"
}

assert_static_android_mpv_deps() {
  local lib="$package_dir/libmpv.so"
  [[ -f "$lib" ]] || die "could not find packaged Android libmpv.so"
  need_cmd readelf

  local forbidden
  forbidden="$(
    readelf -d "$lib" |
      awk -F'[][]' '/NEEDED/ {print $2}' |
      while IFS= read -r dep; do
        case "$dep" in
          libavcodec*|libavfilter*|libavformat*|libavutil*|libavdevice*|\
          libswresample*|libswscale*|libass*|libplacebo*|libmujs*|liblua*|\
          liblcms2*|libz.*|libdav1d*|libfreetype*|libfribidi*|libharfbuzz*|\
          libfontconfig*|libunibreak*|libunwind*|libxxhash*|libmbed*|\
          libxml2*|libiconv*|librubberband*|libuchardet*|libzimg*|\
          libc++_shared*)
            printf '%s\n' "$dep"
            ;;
        esac
      done
  )"
  [[ -z "$forbidden" ]] || die "Android libmpv still has dynamic third-party deps: $forbidden"
}

install_deps
rm -rf "$src_dir" "$package_dir"
mkdir -p "$package_dir"
clone_git_tag https://github.com/mpv-android/mpv-android.git "$mpv_android_ref" "$src_dir"
patch_mpv_android_static_linking

unset TARGET_ARCH
cd "$src_dir/buildscripts"
export WGET="${WGET:-wget --tries=5 --retry-connrefused --waitretry=5 --timeout=60 --read-timeout=60 --progress=dot:giga}"
./download.sh
./buildall.sh --arch "$mpv_arch" mpv

collect_mpv_so
strip_android_mpv
require_mpv_runtime "$package_dir" android
assert_static_android_mpv_deps
zip_package "$package_dir" "$asset_name"
