# ARM64-hosted NDK build

`.github/workflows/build-ndk-arm64.yml` builds an NDK that can run directly on the current `aarch64` Ubuntu environment. It uses GitHub's native `ubuntu-24.04-arm` runner, so the build does not use QEMU or x86 emulation.

The build is intentionally separate from the older `build-aosp-clang.yml` workflow. That workflow produces Android-arm64 ELF binaries, which are target binaries and cannot serve as Linux host tools.

The new workflow:

- starts from Google's official `android-ndk-r28c-linux.zip` and verifies its published size and SHA-1;
- fetches `toolchain/llvm-project` and `toolchain/llvm_android` from Android source at fixed commits;
- applies the matching AOSP patch set;
- builds native ARM64 `clang`, `lld`, and LLVM utilities;
- replaces only the Linux host executables in the official NDK while retaining Google's Android sysroot and target libraries;
- runs an ARM64 host check and an Android ARM64 compile probe;
- uploads the archive together with a SHA-256 manifest.

The artifact is named `android-ndk-r28c-linux-arm64`. After extraction, place the directory under `$ANDROID_SDK_ROOT/ndk/28.2.13676358`.
