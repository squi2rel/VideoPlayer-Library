#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

vlc_input="${VLC_VERSION_INPUT:-latest-3}"
android_libvlc_input="${ANDROID_LIBVLC_VERSION_INPUT:-latest-3}"
mpv_input="${MPV_REF_INPUT:-latest-commit}"
mpv_android_input="${MPV_ANDROID_REF_INPUT:-latest-release}"
mpv_repo_url="${MPV_REPO_URL:-https://github.com/squi2rel/mpv.git}"

latest_vlc_3() {
  local tmp
  tmp="$(mktemp)"
  curl -fsSL 'https://download.videolan.org/pub/videolan/vlc/' >"$tmp"
  python3 - "$tmp" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
versions = sorted(
    set(re.findall(r'href="(3\.0\.[0-9.]+)/"', text)),
    key=lambda s: tuple(int(part) for part in s.split(".")),
)
if not versions:
    raise SystemExit("could not resolve latest VLC 3 release")
print(versions[-1])
PY
  rm -f "$tmp"
}

latest_android_libvlc_3() {
  local tmp
  tmp="$(mktemp)"
  curl -fsSL 'https://repo1.maven.org/maven2/org/videolan/android/libvlc-all/maven-metadata.xml' >"$tmp"
  python3 - "$tmp" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
versions = []
for v in re.findall(r"<version>([^<]+)</version>", text):
    if "eap" in v.lower():
        continue
    if re.fullmatch(r"3\.\d+\.\d+", v):
        versions.append(v)
versions = sorted(set(versions), key=lambda s: tuple(int(part) for part in s.split(".")))
if not versions:
    raise SystemExit("could not resolve latest Android libvlc 3 release")
print(versions[-1])
PY
  rm -f "$tmp"
}

latest_mpv_commit() {
  local ref
  ref="$(git ls-remote "$mpv_repo_url" HEAD | awk 'NR == 1 {print $1}')"
  [[ "$ref" =~ ^[0-9a-f]{40}$ ]] || die "could not resolve latest mpv commit from $mpv_repo_url"
  printf '%s\n' "$ref"
}

latest_mpv_android_tag() {
  local tmp
  tmp="$(mktemp)"
  git ls-remote --tags https://github.com/mpv-android/mpv-android.git |
    awk '{print $2}' |
    sed -E 's#refs/tags/##; s#\^\{\}##' |
    sort -u >"$tmp"
  python3 - "$tmp" <<'PY'
import re
import sys

tags = [line.strip() for line in open(sys.argv[1], encoding="utf-8", errors="ignore") if re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", line.strip())]
tags = sorted(set(tags))
if not tags:
    raise SystemExit("could not resolve latest mpv-android release tag")
print(tags[-1])
PY
  rm -f "$tmp"
}

resolve_value() {
  local input="$1"
  local resolver="$2"
  if [[ "$input" == latest-* ]]; then
    "$resolver"
  else
    printf '%s\n' "$input"
  fi
}

vlc_version="$(resolve_value "$vlc_input" latest_vlc_3)"
android_libvlc_version="$(resolve_value "$android_libvlc_input" latest_android_libvlc_3)"
mpv_ref="$(resolve_value "$mpv_input" latest_mpv_commit)"
mpv_android_ref="$(resolve_value "$mpv_android_input" latest_mpv_android_tag)"

require_vlc_release_version "$vlc_version"
require_android_libvlc_release_version "$android_libvlc_version"
require_mpv_source_ref "$mpv_ref"
require_mpv_android_release_ref "$mpv_android_ref"

log "vlc_version=$vlc_version"
log "android_libvlc_version=$android_libvlc_version"
log "mpv_ref=$mpv_ref"
log "mpv_android_ref=$mpv_android_ref"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "vlc_version=$vlc_version"
    echo "android_libvlc_version=$android_libvlc_version"
    echo "mpv_ref=$mpv_ref"
    echo "mpv_android_ref=$mpv_android_ref"
  } >>"$GITHUB_OUTPUT"
else
  printf 'vlc_version=%s\nandroid_libvlc_version=%s\nmpv_ref=%s\nmpv_android_ref=%s\n' \
    "$vlc_version" "$android_libvlc_version" "$mpv_ref" "$mpv_android_ref"
fi
