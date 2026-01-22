# KernelSU-Next GKI Build (No SUSFS)

Minimal GKI kernel build with KernelSU-Next - **NO SUSFS**.

## Purpose

Baseline test to isolate kernel detection issues. By building without SUSFS, we can determine if detection issues come from:
- KernelSU itself
- SUSFS patches
- Other modifications

## Build

Uses GitHub Actions workflow with:
- KernelSU-Next from rifsxd/KernelSU-Next
- No SUSFS integration
- Clean build flags (removes -dirty from version)
- Standard GKI build process

## Trigger

```bash
gh workflow run "Build KernelSU-Next GKI (No SUSFS)"
```
