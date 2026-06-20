# SYSTEM-FACTS — `apestonks-69` (captured from CachyOS live, 2026-06-20)

Raw discovered values so the build survives the loss of the live USB. Everything here was read off
the running hardware with `blkid` / `lsblk` / `lspci` / `mdadm --detail`.

## GPUs
| Role | Device | PCI ID | Bus |
|---|---|---|---|
| iGPU | Intel Raptor Lake-S UHD 770 | `8086:a780` | 00:02.0 |
| dGPU #1 | NVIDIA GB206 RTX 5060 Ti (Blackwell) | `10de:2d04` | 01:00.0 (behind PEG010 PCIe 5.0 port `8086:a70d`) |
| dGPU #1 audio | NVIDIA GB206 HD Audio | `10de:22eb` | 01:00.1 |
| dGPU #2 | NVIDIA GB206 RTX 5060 Ti (Blackwell) | `10de:2d04` | 08:00.0 (behind PCIe 4.0 port `8086:a74d`) |
| dGPU #2 audio | NVIDIA GB206 HD Audio | `10de:22eb` | 08:00.1 |

- Driver: **NVIDIA 610.43.02** + **ec-jt/open-gpu-kernel-modules** (P2P fork). CUDA 13.3 (Void).
- iGPU driver split: **i915** on Debian+NixOS, **Xe** (`xe.force_probe=a780 i915.force_probe=!a780`) on Void only.
- nvidia modprobe options (from arch): `NVreg_DynamicPowerManagement=0x00`, `NVreg_PreserveVideoMemoryAllocations=0`.
- The two dGPUs sit on separate root ports → P2P needs ReBAR + Above-4G Decoding enabled in BIOS.

## RAID0 — `/home` pool (must present as `/dev/md0`, NEVER md127)
- mdadm array name: `apestonks-69:0`  · level: **raid0**
- **mdadm array UUID: `85172657:de2fb0b4:a9f5a913:98c95b5c`**
- xfs filesystem UUID: **`6df6919b-40b6-44bb-8c19-791c6556ae15`**
- Members (3× 2TB Solidigm/SK hynix SHPP41-2000GM):
  - `/dev/nvme0n1p1` UUID_SUB `389cfd5a-…`
  - `/dev/nvme1n1p1` UUID_SUB `dbfcc175-…`
  - `/dev/nvme2n1p1` UUID_SUB `f21d373d-…`
- `mdadm.conf` (all three OSes):
  ```
  DEVICE partitions
  HOMEHOST <system>
  MAILADDR root
  ARRAY /dev/md0 metadata=1.2 UUID=85172657:de2fb0b4:a9f5a913:98c95b5c
  ```
- Mounted at `/mnt/hot`, per-user bind `/mnt/hot/home/admin → /home/admin`, all `nofail`.
- Shared swapfile: `/mnt/hot/swapfile` (`pri=10`, `nofail`).

## Target USB SSD `sdc` — Transcend TS256GESD310C (238.5G)
| Part | UUID | FS | Label | PARTUUID | Role |
|---|---|---|---|---|---|
| sdc1 | `7B9A-C0BF` | vfat | EFI | a81c3593-… | shared ESP → Debian `/boot/efi` |
| sdc2 | `f88b3051-e515-4ef6-8e44-b4a93b76f6de` | ext4 | debboot | 53862ec5-… | Debian `/boot` |
| sdc3 | `461a6d73-b9d6-4e53-a594-a3c1f657d365` | ext4 | voidboot | 6ea3d31c-… | Void `/boot` |
| sdc4 | `a6b3ef48-b19b-4c34-b6f0-8b21efde5c6c` | ext4 | nixboot | 5722235f-… | NixOS `/boot` |
| sdc5 | `cd997ab2-a636-4537-a186-6302f1f14ba4` | f2fs | debroot | 660742a6-… | Debian `/` |
| sdc6 | `b3a35389-68eb-4158-8bf9-4c296fcd45ab` | **ext4→reformat f2fs** | voidroot | abd39e2a-… | Void `/` (the one wipe) |
| sdc7 | `494196d1-8b53-4076-b26b-ef3f6d0f309c` | btrfs | NIX Store | 17f14d41-… | NixOS `/` (compress=zstd) |

> ⚠️ All seven `sdc` partitions are reformatted, so **every `sdc` UUID above changes** — re-`blkid`
> before writing each OS's fstab. Media: `sdc` is a USB-bridged SSD that reports `rotational=1`
> (btrfs needs the `ssd` flag set explicitly); TRIM passes the bridge (`DISC-MAX 4G`) so `discard=async` is safe.

## Other drives (context — DO NOT TOUCH during the build)
- `sda` 23.6T SATA ST26000DM000 — sda1 btrfs `BPOOL` `0eb3fe37-…` (arch `@var`), sda2 xfs `126dc0a6-…` (arch `/mnt/seagate/newpool`).
- `sdb` 931.5G USB (ASM236X NVMe enclosure) — **existing Arch install**: sdb1 vfat `BCB8-9B79` (`/boot`), sdb2 btrfs `af44fb8e-…` (root, subvols `@`,`@home`,…). Mounted here at `/mnt/arch-root`.
- `nvme3n1p1` 3.6T btrfs `59562f5f-…` (arch `/mnt/warm`).
- `sdd` — this CachyOS live USB (`COS_202604`).

## Identity / conventions
- hostname: `apestonks-69` · primary user `admin` UID/GID **1000** (shared `/home` ⇒ same UID everywhere).
- No graphical boot anywhere; plain getty, manual WM launch.
- WMs: niri (Void, NixOS, wayland) · ctwm on Xorg (Debian only).
- Bootloader: Debian GRUB is the only NVRAM entry, chainloads Void + NixOS via `configfile`.
