# GitHub CI

`Build Runtime Libraries` workflow builds or downloads stable release runtimes for libVLC and libmpv, then uploads zip assets to a timestamped GitHub Release and also updates the moving `runtime-latest` GitHub Release by default.

`native-downloads.json` points at the timestamped release, so older manifests keep downloading the exact zip files that match their recorded SHA-256 hashes even after `runtime-latest` is refreshed.

The workflow intentionally uses release sources instead of nightly sources. Linux libVLC is extracted from the Flathub stable VLC package and validated for a full plugin set, because package-manager VLC builds can miss RTSP-related modules.

Windows libmpv packages are cross-compiled on Ubuntu with llvm-mingw and source-built dependencies for x86, x64, and arm64, avoiding MSYS2 MinGW package gaps.

Android libVLC packages also build and include `libvlc_jvm_bridge.so`, which initializes VLC's JNI entry point from the app-side bridge.

Runtime zip files extract directly to native libraries at the archive root. Desktop/Linux libVLC zips also include a root `plugins/` directory; Android libVLC zips contain only the ABI's `.so` files.
