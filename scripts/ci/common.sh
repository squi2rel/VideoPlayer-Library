#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST_DIR="${DIST_DIR:-$REPO_ROOT/dist}"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/.runtime-work}"

mkdir -p "$DIST_DIR" "$WORK_DIR"

log() {
  printf '[runtime-ci] %s\n' "$*" >&2
}

die() {
  printf '[runtime-ci] error: %s\n' "$*" >&2
  exit 1
}

print_ffmpeg_config_log() {
  local log_file="${1:-ffbuild/config.log}"

  if [[ ! -f "$log_file" ]]; then
    log "FFmpeg configure failed; $log_file was not created"
    return 0
  fi

  log "FFmpeg configure failed; printing $log_file"
  printf '%s\n' "----- begin $log_file -----" >&2
  cat "$log_file" >&2 || true
  printf '%s\n' "----- end $log_file -----" >&2
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

install_pip_meson() {
  local min_version="${1:-1.6.1}"

  install_pip_package "meson>=$min_version"
  need_cmd meson
  log "meson $(meson --version)"
}

install_pip_package() {
  local package="$1"

  need_cmd python3
  if ! python3 -m pip install --user --break-system-packages "$package"; then
    python3 -m pip install --user "$package"
  fi

  export PATH="$HOME/.local/bin:$PATH"
  hash -r
}

download_url() {
  local url="$1"
  local out="$2"
  local retry_args=(--retry 5 --retry-delay 5 --connect-timeout 30)

  if curl --help all 2>/dev/null | grep -q -- '--retry-all-errors'; then
    retry_args+=(--retry-all-errors)
  fi

  log "download $url"
  curl -fL "${retry_args[@]}" -o "$out" "$url"
}

git_retry() {
  local attempt status
  for attempt in 1 2 3 4 5; do
    if "$@"; then
      return 0
    else
      status=$?
    fi
    if [[ "$attempt" -eq 5 ]]; then
      return "$status"
    fi
    log "git command failed with $status, retrying in 5s: $*"
    sleep 5
  done
}

git_clone_retry() {
  local dest="${@: -1}"
  local attempt status

  for attempt in 1 2 3 4 5; do
    rm -rf "$dest"
    if git clone "$@"; then
      return 0
    else
      status=$?
    fi
    if [[ "$attempt" -eq 5 ]]; then
      return "$status"
    fi
    log "git clone failed with $status, retrying in 5s: $*"
    sleep 5
  done
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

select_href() {
  local base_url="$1"
  local regex="$2"
  local html_file="$3"
  python3 - "$base_url" "$regex" "$html_file" <<'PY'
import html
import re
import sys
from urllib.parse import urljoin

base_url, pattern, html_file = sys.argv[1:]
text = open(html_file, encoding="utf-8", errors="ignore").read()
hrefs = [html.unescape(x) for x in re.findall(r'href=["\']([^"\']+)["\']', text)]
matches = [h for h in hrefs if re.search(pattern, h) and "debug" not in h.lower()]
if not matches:
    raise SystemExit(f"no href matching {pattern!r}")

def score(name: str) -> tuple[int, str]:
    lower = name.lower()
    # Prefer directly extractable runtime archives over installers.
    order = [".zip", ".7z", ".dmg", ".aar", ".tar.xz"]
    for idx, suffix in enumerate(order):
        if lower.endswith(suffix):
            return (idx, name)
    return (len(order), name)

print(urljoin(base_url, sorted(matches, key=score)[0]))
PY
}

zip_package() {
  local package_dir="$1"
  local asset_name="$2"
  local zip_path="$DIST_DIR/$asset_name.zip"
  find "$package_dir" -mindepth 1 -print -quit | grep -q . || die "package directory is empty: $package_dir"
  rm -f "$zip_path"
  (cd "$package_dir" && zip -qr "$zip_path" .)
  log "created $zip_path"
  printf '%s\n' "$zip_path"
}

require_any_file() {
  local root="$1"
  local label="$2"
  shift 2
  local pattern
  for pattern in "$@"; do
    if find "$root" -type f -iname "$pattern" -print -quit | grep -q .; then
      return 0
    fi
  done
  die "missing $label in $root"
}

require_vlc_runtime() {
  local root="$1"
  local platform="$2"
  local check_rtsp="${3:-true}"

  case "$platform" in
    windows)
      require_any_file "$root" "libvlc.dll" "libvlc.dll"
      require_any_file "$root" "libvlccore.dll" "libvlccore.dll"
      ;;
    macos)
      require_any_file "$root" "libvlc dylib" "libvlc*.dylib"
      require_any_file "$root" "libvlccore dylib" "libvlccore*.dylib"
      ;;
    linux | android)
      require_any_file "$root" "libvlc.so" "libvlc.so" "libvlc.so.*"
      if [[ "$platform" == "android" ]]; then
        require_any_file "$root" "libvlcjni.so" "libvlcjni.so"
      else
        require_any_file "$root" "libvlccore.so" "libvlccore.so" "libvlccore.so.*"
      fi
      ;;
    *)
      die "unknown VLC platform: $platform"
      ;;
  esac

  if [[ "$check_rtsp" == "true" ]]; then
    require_any_file "$root" "VLC RTSP/live555 plugin" "*live555*plugin*"
  fi
}

require_mpv_runtime() {
  local root="$1"
  local platform="$2"

  case "$platform" in
    windows)
      require_any_file "$root" "libmpv dll" "libmpv*.dll" "mpv-*.dll"
      ;;
    macos)
      require_any_file "$root" "libmpv dylib" "libmpv*.dylib"
      ;;
    linux | android)
      require_any_file "$root" "libmpv.so" "libmpv.so" "libmpv.so.*"
      ;;
    *)
      die "unknown mpv platform: $platform"
      ;;
  esac
}

assert_not_nightly_url() {
  local url="$1"
  local lower
  lower="$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lower" == *nightly* ]]; then
    die "nightly source is not allowed: $url"
  fi
}

require_vlc_release_version() {
  local version="$1"
  [[ "$version" =~ ^[0-9]+(\.[0-9]+)+$ ]] || die "VLC version must be a numeric release version: $version"
}

require_android_libvlc_release_version() {
  local version="$1"
  local lower
  lower="$(printf '%s' "$version" | tr '[:upper:]' '[:lower:]')"
  [[ "$version" =~ ^[0-9]+(\.[0-9]+)+$ ]] || die "Android libVLC version must be a numeric release version: $version"
  [[ "$lower" != *eap* && "$lower" != *nightly* ]] || die "Android libVLC version must be a stable release: $version"
}

require_mpv_release_ref() {
  local ref="$1"
  [[ "$ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "mpv ref must be a release tag like v0.41.0: $ref"
}

require_mpv_source_ref() {
  local ref="$1"
  [[ "$ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ || "$ref" =~ ^[0-9a-f]{40}$ ]] ||
    die "mpv ref must be a release tag like v0.41.0 or a full commit hash: $ref"
}

require_mpv_android_release_ref() {
  local ref="$1"
  [[ "$ref" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "mpv-android ref must be a date release tag like 2026-04-25: $ref"
}

clone_git_tag() {
  local repo_url="$1"
  local tag="$2"
  local dest="$3"

  need_cmd git
  rm -rf "$dest"
  git init "$dest"
  git -C "$dest" remote add origin "$repo_url"
  git_retry git -C "$dest" fetch --depth 1 origin "refs/tags/$tag:refs/tags/$tag"
  git -C "$dest" checkout --detach "refs/tags/$tag"
}

clone_git_ref() {
  local repo_url="$1"
  local ref="$2"
  local dest="$3"

  need_cmd git
  rm -rf "$dest"
  git init "$dest"
  git -C "$dest" remote add origin "$repo_url"
  if [[ "$ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    git_retry git -C "$dest" fetch --depth 1 origin "refs/tags/$ref:refs/tags/$ref"
    git -C "$dest" checkout --detach "refs/tags/$ref"
  else
    git_retry git -C "$dest" fetch --depth 1 origin "$ref"
    git -C "$dest" checkout --detach FETCH_HEAD
  fi
}
