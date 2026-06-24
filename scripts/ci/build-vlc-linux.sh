#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

target_arch="${TARGET_ARCH:?TARGET_ARCH is required}"
requested_vlc_version="${VLC_VERSION:?VLC_VERSION is required}"

require_vlc_release_version "$requested_vlc_version"

asset_name="libvlc-linux-$target_arch"
flatpak_app="org.videolan.VLC"
flatpak_ref="app/$flatpak_app/$(uname -m)/stable"
source_url="https://flathub.org/apps/$flatpak_app"
package_dir="$WORK_DIR/$asset_name"

assert_not_nightly_url "$source_url"

install_flatpak_deps() {
  if [[ "${SKIP_APT_INSTALL:-false}" == "true" ]]; then
    return
  fi

  sudo apt-get update
  sudo apt-get install -y --no-install-recommends ca-certificates flatpak zip
}

flatpak_info_value() {
  local label="$1"
  flatpak --user info "$flatpak_app" | awk -F: -v label="$label" '
    $1 ~ label {
      sub(/^[ \t]+/, "", $2)
      print $2
      exit
    }
  '
}

require_vlc_linux_full_modules() {
  local root="$1"
  local plugins="$root/plugins"
  [[ -d "$plugins" ]] || die "missing VLC plugin directory: $plugins"

  local plugin_count
  plugin_count="$(find "$plugins" -type f -name '*.so' | wc -l | tr -d ' ')"
  [[ "$plugin_count" -ge 300 ]] || die "VLC Flatpak plugin set looks incomplete: only $plugin_count modules"

  require_any_file "$plugins" "VLC live555/RTSP plugin" "liblive555_plugin.so"
  require_any_file "$plugins" "VLC HTTP plugin" "libhttp_plugin.so"
  require_any_file "$plugins" "VLC HTTPS plugin" "libhttps_plugin.so"
  require_any_file "$plugins" "VLC RTP plugin" "librtp_plugin.so"
  require_any_file "$plugins" "VLC SMB plugin" "libsmb_plugin.so"
  require_any_file "$plugins" "VLC DVD navigation plugin" "libdvdnav_plugin.so"
  require_any_file "$plugins" "VLC DVD read plugin" "libdvdread_plugin.so"
  require_any_file "$plugins" "VLC Blu-ray plugin" "liblibbluray_plugin.so"
  require_any_file "$plugins" "VLC FFmpeg codec plugin" "libavcodec_plugin.so"
  require_any_file "$plugins" "VLC Matroska demux plugin" "libmkv_plugin.so"
  require_any_file "$plugins" "VLC MP4 demux plugin" "libmp4_plugin.so"
  require_any_file "$plugins" "VLC H.264 packetizer" "libpacketizer_h264_plugin.so"
  require_any_file "$plugins" "VLC HEVC packetizer" "libpacketizer_hevc_plugin.so"
}

package_flatpak_vlc() {
  need_cmd flatpak
  need_cmd zip

  rm -rf "$package_dir"
  mkdir -p "$package_dir"

  flatpak --user remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  flatpak --user install -y --noninteractive flathub "$flatpak_app//stable"

  local location actual_version commit plugin_count notes
  location="$(flatpak --user info --show-location "$flatpak_app")"
  actual_version="$(flatpak_info_value Version)"
  commit="$(flatpak --user info --show-commit "$flatpak_app")"

  [[ -d "$location/files/lib" ]] || die "missing Flatpak lib directory: $location/files/lib"
  [[ -d "$location/files/lib/vlc/plugins" ]] || die "missing Flatpak VLC plugins directory: $location/files/lib/vlc/plugins"
  [[ "$actual_version" == "$requested_vlc_version" ]] || die "Flathub VLC version $actual_version does not match requested VLC version $requested_vlc_version"

  shopt -s nullglob
  cp -a "$location/files/lib"/*.so* "$package_dir/"
  shopt -u nullglob
  cp -a "$location/files/lib/vlc/plugins" "$package_dir/plugins"

  require_vlc_runtime "$package_dir" linux true
  require_vlc_linux_full_modules "$package_dir"

  plugin_count="$(find "$package_dir/plugins" -type f -name '*.so' | wc -l | tr -d ' ')"
  notes="Flathub stable $flatpak_ref commit $commit with $plugin_count VLC plugin modules"
  log "$notes"
  zip_package "$package_dir" "$asset_name"
}

install_flatpak_deps
package_flatpak_vlc
