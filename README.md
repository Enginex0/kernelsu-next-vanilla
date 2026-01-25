# KernelSU-Next + SUSFS GKI Builder

Build GKI kernels with KernelSU-Next root and comprehensive SUSFS hiding support.

## Features

| Feature | Description |
|---------|-------------|
| **KernelSU-Next** | Root access with SUSFS integration |
| **SUSFS (11 features)** | Complete root hiding from detection apps |
| **NoMount VFS** | Kernel-level file path redirection |
| **kstat_redirect** | Proper stat() spoofing via redirect API |
| **Unicode Filter** | Block paths with suspicious unicode |

### SUSFS Features Enabled

```
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_UNICODE_FILTER=y
```

## Quick Start

### GitHub Actions (Easiest)

1. Fork this repo
2. Go to **Actions** > **Build KernelSU-Next GKI + SUSFS**
3. Click **Run workflow**
4. Select your kernel version and device
5. Download the AnyKernel3 zip when complete

### Manual Build

```bash
# 1. Sync GKI kernel
repo init -u https://android.googlesource.com/kernel/manifest -b common-android12-5.10-2024-05 --depth=1
repo sync -c -j$(nproc)

# 2. Add KernelSU-Next (dev_susfs branch)
curl -LSs "https://raw.githubusercontent.com/rifsxd/KernelSU-Next/dev_susfs/kernel/setup.sh" | bash -s dev_susfs

# 3. Add custom SUSFS kernel patches (all 11 features)
git clone https://github.com/Enginex0/susfs4ksu.git -b gki-android12-5.10
cp susfs4ksu/kernel_patches/fs/susfs.c common/fs/
cp susfs4ksu/kernel_patches/include/linux/*.h common/include/linux/
patch -p1 -d common < susfs4ksu/kernel_patches/50_add_susfs_in_gki-android12-5.10.patch

# 4. Add NoMount VFS
git clone https://github.com/Enginex0/nomount-vfs.git
patch -p1 -d common < nomount-vfs/patches/nomount-core-5.10.patch
# Run inject scripts for hooks...

# 5. Configure & Build
tools/bazel build --config=fast --config=stamp --lto=thin //common:kernel_aarch64_dist
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Detection App (Momo)                      │
│                         stat()                               │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                     SUSFS kstat_redirect                     │
│              Spoofs device ID: fd2fh → fd05h                 │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                       NoMount VFS                            │
│           Redirects: /system/X → /data/adb/modules/X        │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Module Files on /data                     │
└─────────────────────────────────────────────────────────────┘
```

## Supported Configurations

| Android | Kernel | SUSFS Branch |
|---------|--------|--------------|
| 12 | 5.10 | `gki-android12-5.10` |
| 13 | 5.10/5.15 | `gki-android13-5.10` / `gki-android13-5.15` |
| 14 | 5.15/6.1 | `gki-android14-5.15` / `gki-android14-6.1` |
| 15 | 6.6 | `gki-android15-6.6` |

## Credits

- [rifsxd/KernelSU-Next](https://github.com/rifsxd/KernelSU-Next) - KernelSU-Next
- [simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) - Original SUSFS
- [Enginex0/susfs4ksu](https://github.com/Enginex0/susfs4ksu) - Custom SUSFS fork (11 features)
- [Enginex0/nomount-vfs](https://github.com/Enginex0/nomount-vfs) - NoMount VFS hiding
- [WildKernels](https://github.com/WildKernels) - AnyKernel3 GKI support
