# GitHub CI

`Build Runtime Libraries` workflow builds or downloads stable release runtimes for libVLC and libmpv, then uploads zip assets to a timestamped GitHub Release and also updates the moving `runtime-latest` GitHub Release by default.

`native-downloads.json` points at the timestamped release, so older manifests keep downloading the exact zip files that match their recorded SHA-256 hashes even after `runtime-latest` is refreshed.

The workflow intentionally uses release sources instead of nightly sources. Linux libVLC is extracted from the Flathub stable VLC package and validated for a full plugin set, because package-manager VLC builds can miss RTSP-related modules.

libmpv packages keep the output as loadable shared libraries, but build core third-party media dependencies as static libraries from pinned release tags and reject packages that still import loose FFmpeg/libass/libplacebo/Lua/rubberband/uchardet/zimg/shaderc/etc. runtime libraries. Linux libmpv enables the audio, video, and hardware-decoding backends while allowing the host system's platform ABI libraries such as X11, Wayland, EGL, VAAPI, VDPAU, PulseAudio, PipeWire, and Vulkan to resolve from the OS. Windows libmpv is cross-compiled on Ubuntu with llvm-mingw for x86, x64, and arm64; the zip contains only the final `libmpv` DLL, with the Vulkan loader statically linked when Vulkan is enabled.

Android libVLC packages also build and include `libvlc_jvm_bridge.so`, which initializes VLC's JNI entry point from the app-side bridge.

Runtime zip files extract directly to native libraries at the archive root. Desktop/Linux libVLC zips also include a root `plugins/` directory; Android libVLC zips contain only the ABI's `.so` files.
