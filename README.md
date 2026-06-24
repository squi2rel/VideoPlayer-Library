# libVLC-Archive
LibVLC library  
version < 1.5.8 libVLC 4  
version >= 1.5.8 libVLC 3  
See Release

## GitHub CI

`Build Runtime Libraries` workflow builds or downloads stable release runtimes for libVLC and libmpv, then uploads zip assets to the `runtime-latest` GitHub Release by default.

The workflow intentionally uses release sources instead of nightly sources. Linux libVLC is extracted from the Flathub stable VLC package and validated for a full plugin set, because package-manager VLC builds can miss RTSP-related modules.

Windows libmpv packages are cross-compiled on Ubuntu with llvm-mingw and source-built dependencies for x86, x64, and arm64, avoiding MSYS2 MinGW package gaps.

Android libVLC packages also build and include `libvlc_jvm_bridge.so`, which initializes VLC's JNI entry point from the app-side bridge.

Runtime zip files extract directly to native libraries at the archive root. Desktop/Linux libVLC zips also include a root `plugins/` directory; Android libVLC zips contain only the ABI's `.so` files.

# 关于Android设备
仅供高级用户  
下载[Release](https://github.com/squi2rel/VideoPlayer-Library/releases/tag/vlc3)内VideoPlayer-vlc3-android-all.zip，使用任意带有apk修改功能的文件管理器解压到启动器apk的根目录即可  
需要VideoPlayer版本 >= 1.6.4.1
