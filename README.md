# apestonks-69 — triple-boot USB build

Bootstrap **Debian (master) + Void + NixOS** onto one USB SSD (`sdc`), sharing one EFI, one
RAID0 `/home` (`/dev/md0`), and one identity — assembled from inside a CachyOS live env.
CUDA dev box with **2× RTX 5060 Ti** running the **ec-jt P2P open-gpu-kernel-modules** fork.

> Backed up here because the live USB this was authored on is unreliable. Nothing secret inside —
> just hardware IDs and install steps.

## Contents
- **[PLAN.md](PLAN.md)** — the full runbook: partition map, per-distro bootstrap (debootstrap / Void
  rootfs / nixos-install), Debian-master GRUB chainloading, `md0` clamp, `nofail` bind `/home`,
  shared swapfile, i915-vs-Xe split, and the NVIDIA 610.43.02 / CUDA / ec-jt stack on Void+NixOS.
- **[SYSTEM-FACTS.md](SYSTEM-FACTS.md)** — every real UUID / PCI ID / partition layout read off the
  live hardware, so the build survives losing the stick.

## Status
Planning complete; execution **not yet started** (no destructive ops have run). The only destructive
disk step in the whole plan is `mkfs.f2fs` on `sdc6` (Void root).
