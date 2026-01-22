# KernelSU-Next + SUSFS GKI Builder

Build GKI kernels with KernelSU-Next root and SUSFS hiding support.

## Quick Start

### GitHub Actions (Easiest)

1. Fork this repo
2. Go to **Actions** > **Build KernelSU-Next GKI + SUSFS**
3. Click **Run workflow**
4. Select your kernel version and device
5. Download the AnyKernel3 zip when complete

### Manual Build (One-liner summary)

```bash
# 1. Sync GKI kernel
repo init -u https://android.googlesource.com/kernel/manifest -b common-android12-5.10-2024-05 --depth=1
repo sync -c -j$(nproc)

# 2. Add KernelSU-Next (dev_susfs branch for SUSFS support)
curl -LSs "https://raw.githubusercontent.com/rifsxd/KernelSU-Next/dev_susfs/kernel/setup.sh" | bash -s dev_susfs

# 3. Add SUSFS kernel patches
git clone https://gitlab.com/simonpunk/susfs4ksu.git -b gki-android12-5.10
cp susfs4ksu/kernel_patches/fs/* common/fs/
cp susfs4ksu/kernel_patches/include/linux/* common/include/linux/
patch -p1 -d common < susfs4ksu/kernel_patches/50_add_susfs_in_gki-android12-5.10.patch

# 4. Configure
echo -e "CONFIG_KSU=y\nCONFIG_KSU_SUSFS=y" >> common/arch/arm64/configs/gki_defconfig

# 5. Build
tools/bazel build --config=fast --config=stamp --lto=thin //common:kernel_aarch64_dist
```

## Why Two Steps for SUSFS?

| Component | What It Does | How to Add |
|-----------|--------------|------------|
| **KernelSU-Next** | Root access | `setup.sh` script |
| **SUSFS** | Hide root from apps | Kernel patches (separate) |

KernelSU-Next's `setup.sh` only sets up KernelSU-Next. SUSFS is a **separate project** that requires kernel-level patches. The `dev_susfs` branch of KernelSU-Next has code that *uses* SUSFS APIs, but you still need to *add* SUSFS to the kernel.

## Documentation

See **[docs/SETUP_GUIDE.md](docs/SETUP_GUIDE.md)** for:
- Detailed step-by-step instructions
- Branch selection guide
- Troubleshooting
- FAQ

## Supported Configurations

| Android | Kernel | SUSFS Branch |
|---------|--------|--------------|
| 12 | 5.10 | `gki-android12-5.10` |
| 13 | 5.10/5.15 | `gki-android13-5.10` / `gki-android13-5.15` |
| 14 | 5.15/6.1 | `gki-android14-5.15` / `gki-android14-6.1` |
| 15 | 6.6 | `gki-android15-6.6` |

## Credits

- [rifsxd/KernelSU-Next](https://github.com/rifsxd/KernelSU-Next) - KernelSU-Next
- [simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) - SUSFS
- [WildKernels](https://github.com/WildKernels) - AnyKernel3 GKI support
