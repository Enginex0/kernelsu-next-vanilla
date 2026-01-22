# KernelSU-Next + SUSFS GKI Kernel Build Guide

A complete guide to building GKI kernels with KernelSU-Next and SUSFS integration.

---

## Table of Contents

1. [Understanding the Components](#understanding-the-components)
2. [Why It's Not "One Script"](#why-its-not-one-script)
3. [Prerequisites](#prerequisites)
4. [Quick Start (GitHub Actions)](#quick-start-github-actions)
5. [Manual Build Steps](#manual-build-steps)
6. [Troubleshooting](#troubleshooting)
7. [FAQ](#faq)

---

## Understanding the Components

### What Are We Building?

```
┌─────────────────────────────────────────────────────────────┐
│                     Final Kernel Image                       │
├─────────────────────────────────────────────────────────────┤
│  GKI Kernel Source (Google)                                  │
│  ├── KernelSU-Next (root solution)                          │
│  │   └── Branch: dev_susfs (SUSFS-aware code)               │
│  └── SUSFS Patches (hiding infrastructure)                   │
│      ├── fs/susfs.c                                         │
│      ├── include/linux/susfs.h                              │
│      └── Kernel file modifications                          │
└─────────────────────────────────────────────────────────────┘
```

### Component Breakdown

| Component | Source | Purpose |
|-----------|--------|---------|
| **GKI Kernel** | `android.googlesource.com` | Base Android kernel |
| **KernelSU-Next** | `github.com/rifsxd/KernelSU-Next` | Root access solution (fork of KernelSU) |
| **SUSFS** | `gitlab.com/simonpunk/susfs4ksu` | Filesystem hiding (mounts, files, processes) |

### Branch Selection for KernelSU-Next

| Branch | SUSFS Support | Use Case |
|--------|---------------|----------|
| `next` | No | KernelSU-Next without SUSFS |
| `dev_susfs` | Yes | KernelSU-Next with SUSFS integration |
| `next-susfs-a13-5.15-dev` | Yes | Specific Android 13 / 5.15 builds |
| `next-susfs-a14-6.1-dev` | Yes | Specific Android 14 / 6.1 builds |

---

## Why It's Not "One Script"

**Common question:** "Why can't I just run one setup.sh and build?"

**Answer:** KernelSU-Next and SUSFS are **separate projects** maintained by different developers:

```
KernelSU-Next (rifsxd)          SUSFS (simonpunk)
        │                              │
        │   setup.sh only handles      │   Requires kernel-level
        │   KernelSU-Next code         │   patches to fs/, include/
        │                              │
        └──────────┬───────────────────┘
                   │
                   ▼
           Integration needed
           (this is what build
            workflows do)
```

**What setup.sh does:**
- Clones KernelSU-Next repository
- Creates symlink in `drivers/kernelsu`
- Modifies `drivers/Makefile` and `drivers/Kconfig`

**What setup.sh does NOT do:**
- Apply SUSFS kernel patches
- Copy `susfs.h` and `susfs.c` to kernel
- Configure kernel options

---

## Prerequisites

### For GitHub Actions (Recommended)

- GitHub account
- Fork of this repository
- ~30 minutes for build

### For Local Build

- Ubuntu 20.04+ or similar Linux
- 50GB+ free disk space
- 16GB+ RAM recommended
- `git`, `curl`, `python3`, `repo` tool
- Clang/LLVM toolchain (provided by kernel build system)

---

## Quick Start (GitHub Actions)

### Step 1: Fork the Repository

Fork `Enginex0/kernelsu-next-vanilla` to your GitHub account.

### Step 2: Trigger Build

1. Go to **Actions** tab
2. Select **"Build KernelSU-Next GKI + SUSFS"**
3. Click **"Run workflow"**
4. Configure:
   - `android_version`: android12, android13, android14, android15
   - `kernel_version`: 5.10, 5.15, 6.1, 6.6
   - `sub_level`: Your kernel sublevel (e.g., 209)
   - `os_patch_level`: YYYY-MM format (e.g., 2024-05)
   - `device_codename`: Your device (for stock kernel spoofing)

### Step 3: Download Artifact

After build completes (~20-30 min), download the AnyKernel3 zip from **Artifacts**.

### Step 4: Flash

Flash via TWRP or KernelFlasher app.

---

## Manual Build Steps

### Step 1: Setup Environment

```bash
# Create workspace
mkdir -p ~/gki-build && cd ~/gki-build

# Install repo tool
mkdir -p ~/.bin
curl https://storage.googleapis.com/git-repo-downloads/repo > ~/.bin/repo
chmod a+x ~/.bin/repo
export PATH="$HOME/.bin:$PATH"
```

### Step 2: Sync Kernel Source

```bash
# Example for Android 12, kernel 5.10, patch level 2024-05
mkdir android12-5.10 && cd android12-5.10

repo init -u https://android.googlesource.com/kernel/manifest \
    -b common-android12-5.10-2024-05 \
    --depth=1

repo sync -c -j$(nproc) --no-tags
```

### Step 3: Add KernelSU-Next (with SUSFS support)

```bash
cd ~/gki-build/android12-5.10

# Use dev_susfs branch for SUSFS support
curl -LSs "https://raw.githubusercontent.com/rifsxd/KernelSU-Next/dev_susfs/kernel/setup.sh" | bash -s dev_susfs
```

**What this does:**
- Clones `KernelSU-Next/KernelSU-Next` repo
- Checks out `dev_susfs` branch
- Creates symlink: `common/drivers/kernelsu` -> `KernelSU-Next/kernel`
- Adds to `drivers/Makefile`: `obj-$(CONFIG_KSU) += kernelsu/`
- Adds to `drivers/Kconfig`: `source "drivers/kernelsu/Kconfig"`

### Step 4: Apply SUSFS Kernel Patches

```bash
# Clone SUSFS patches (match your kernel version)
git clone https://gitlab.com/simonpunk/susfs4ksu.git \
    -b gki-android12-5.10 \
    ~/gki-build/susfs4ksu

cd ~/gki-build/android12-5.10/common

# Copy SUSFS source files
cp ~/gki-build/susfs4ksu/kernel_patches/fs/* ./fs/
cp ~/gki-build/susfs4ksu/kernel_patches/include/linux/* ./include/linux/

# Apply SUSFS integration patch
patch -p1 < ~/gki-build/susfs4ksu/kernel_patches/50_add_susfs_in_gki-android12-5.10.patch
```

**What this does:**
- Adds `fs/susfs.c` - SUSFS core implementation
- Adds `include/linux/susfs.h` - SUSFS header
- Patches kernel files to call SUSFS functions:
  - `fs/namei.c` - path resolution hooks
  - `fs/open.c` - file open hooks
  - `fs/read_write.c` - read/write hooks
  - `fs/stat.c` - stat spoofing
  - `fs/proc/task_mmu.c` - maps hiding
  - `fs/proc_namespace.c` - mount hiding
  - And more...

### Step 5: Configure Kernel

```bash
cd ~/gki-build/android12-5.10/common

# Add KernelSU and SUSFS configs
cat >> arch/arm64/configs/gki_defconfig << 'EOF'
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
EOF
```

### Step 6: Clean Build Flags (Optional - for stealth)

```bash
cd ~/gki-build/android12-5.10

# Remove -dirty suffix from kernel version
sed -i 's/-dirty//' ./common/scripts/setlocalversion

# For Bazel builds, also remove -maybe-dirty
sed -i "/stable_scmversion_cmd/s/-maybe-dirty//g" ./build/kernel/kleaf/impl/stamp.bzl
```

### Step 7: Build

```bash
cd ~/gki-build/android12-5.10

# For newer kernels (Bazel)
tools/bazel build --config=fast --config=stamp --lto=thin //common:kernel_aarch64_dist

# For older kernels (build.sh)
LTO=thin BUILD_CONFIG=common/build.config.gki.aarch64 build/build.sh
```

### Step 8: Package with AnyKernel3

```bash
git clone https://github.com/WildKernels/AnyKernel3.git -b gki-2.0

# Copy kernel image
cp ~/gki-build/android12-5.10/bazel-bin/common/kernel_aarch64/Image ./AnyKernel3/

# Create flashable zip
cd AnyKernel3
zip -r9 ../KSU-Next-SUSFS-5.10.209.zip * -x .git/*
```

---

## Troubleshooting

### Error: `'linux/susfs.h' file not found`

**Cause:** SUSFS kernel patches not applied.

**Fix:** Run Step 4 (Apply SUSFS Kernel Patches).

### Error: `CONFIG_KSU_SUSFS undeclared`

**Cause:** Using wrong KernelSU-Next branch.

**Fix:** Use `dev_susfs` branch:
```bash
curl -LSs ".../dev_susfs/kernel/setup.sh" | bash -s dev_susfs
```

### Error: SUSFS patch fails with rejects

**Cause:** Patch offsets don't match your kernel version.

**Fix:**
1. Check you're using correct SUSFS branch for your kernel
2. Apply with `patch -p1 --no-backup-if-mismatch < patch.patch || true`
3. Manually fix any `.rej` files

### Error: `unsupported device` when flashing

**Cause:** Using generic AnyKernel3 instead of GKI version.

**Fix:** Use WildKernels AnyKernel3:
```bash
git clone https://github.com/WildKernels/AnyKernel3.git -b gki-2.0
```

### Kernel boots but SUSFS not working

**Cause:** `CONFIG_KSU_SUSFS=y` not set.

**Fix:** Verify config:
```bash
grep CONFIG_KSU_SUSFS .config
# Should show: CONFIG_KSU_SUSFS=y
```

---

## FAQ

### Q: Which branch should I use?

| Your Goal | KernelSU-Next Branch | SUSFS Needed? |
|-----------|---------------------|---------------|
| Root only, no hiding | `next` | No |
| Root + hiding (recommended) | `dev_susfs` | Yes |

### Q: What's the difference between KernelSU and KernelSU-Next?

KernelSU-Next is a fork with additional features and active development by rifsxd. It's compatible with SUSFS when using the `dev_susfs` branch.

### Q: Can I use this with custom kernels (not GKI)?

Yes, but you may need to adjust paths. The process is similar:
1. Add KernelSU-Next via setup.sh
2. Apply SUSFS patches
3. Build

### Q: How do I update KernelSU-Next?

```bash
cd ~/gki-build/android12-5.10/KernelSU-Next
git pull
git checkout dev_susfs  # or desired branch
```

### Q: How do I add stock kernel spoofing?

Create a `device-profiles.json` with your device's stock kernel info, then patch `scripts/setlocalversion` to return the stock release string. See the workflow for implementation details.

---

## SUSFS Branch Compatibility Matrix

| Android | Kernel | SUSFS Branch |
|---------|--------|--------------|
| 12 | 5.10 | `gki-android12-5.10` |
| 13 | 5.10 | `gki-android13-5.10` |
| 13 | 5.15 | `gki-android13-5.15` |
| 14 | 5.15 | `gki-android14-5.15` |
| 14 | 6.1 | `gki-android14-6.1` |
| 15 | 6.6 | `gki-android15-6.6` |

---

## Quick Reference

```bash
# One-liner: Add KernelSU-Next with SUSFS support
curl -LSs "https://raw.githubusercontent.com/rifsxd/KernelSU-Next/dev_susfs/kernel/setup.sh" | bash -s dev_susfs

# Clone SUSFS patches
git clone https://gitlab.com/simonpunk/susfs4ksu.git -b gki-android12-5.10

# Apply SUSFS
cp susfs4ksu/kernel_patches/fs/* common/fs/
cp susfs4ksu/kernel_patches/include/linux/* common/include/linux/
patch -p1 -d common < susfs4ksu/kernel_patches/50_add_susfs_in_gki-android12-5.10.patch

# Config
echo "CONFIG_KSU=y" >> common/arch/arm64/configs/gki_defconfig
echo "CONFIG_KSU_SUSFS=y" >> common/arch/arm64/configs/gki_defconfig

# Build
tools/bazel build --config=fast --config=stamp --lto=thin //common:kernel_aarch64_dist
```

---

## Resources

- [KernelSU-Next GitHub](https://github.com/rifsxd/KernelSU-Next)
- [SUSFS GitLab](https://gitlab.com/simonpunk/susfs4ksu)
- [WildKernels AnyKernel3](https://github.com/WildKernels/AnyKernel3)
- [GKI Kernel Documentation](https://source.android.com/docs/core/architecture/kernel/gki-release-builds)

---

*Last updated: January 2026*
