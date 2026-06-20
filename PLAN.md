# Triple-boot bootstrap: Debian (master) + Void + NixOS — `apestonks-69`

## Context

Booted into an **ephemeral CachyOS live USB** (archiso, in RAM, pacman works, fully `-Syyu`'d).
Goal: hand-assemble three Linux installs onto the `sdc` SSD (238G) from inside this live env,
sharing one EFI, one `/home` (RAID0), and one identity. **Debian is the master** — it owns the
only GRUB in NVRAM and chainloads the other two ("deb feeds them grub, they kiss debian's boots").
This box is a **CUDA dev workstation** with **2× RTX 5060 Ti (Blackwell)** that need
**peer-to-peer** via the `ec-jt/open-gpu-kernel-modules` fork, plus an Intel Raptor Lake iGPU
(i915 on Debian/NixOS, experimental **Xe** on Void). NixOS tracks `nixos-unstable` (bleeding edge).

Everything here is a runbook to execute *after* plan approval. Nothing destructive has run yet.

---

## Hard parameters (verified this session)

| Thing | Value |
|---|---|
| Firmware | UEFI |
| Target disk | `sdc` = **USB SSD** (Transcend TS256GESD310C, 238.5G) — distros run off USB by design |
| iGPU | Intel RPL-S UHD 770 (`8086:a780` @ 00:02.0) → **i915** on Debian+NixOS · **Xe** on Void only |
| dGPU ×2 | NVIDIA RTX 5060 Ti GB206 (Blackwell) — PCI `10de:2d04` @ 01:00.0 + 08:00.0 |
| `/home` array | RAID0 xfs, **UUID `6df6919b-40b6-44bb-8c19-791c6556ae15`**, mdadm name `apestonks-69:0` → `/dev/md0` |
| RAID backup | `nvme3n1` 3.6T btrfs — **DO NOT TOUCH** |
| Void rootfs | `~/Downloads/void-x86_64-ROOTFS-20250202.tar.xz` (**glibc**) |
| Hostname (all 3) | `apestonks-69` |
| User (all 3) | **`admin`**, UID/GID **1000** (must match — shared `/home`) |
| Locale / TZ / keymap | `en_US.UTF-8` · **`America/New_York`** · `us` (read from your arch install, NOT the live env's UTC) |
| Swap | **single shared swapfile on the array** (`/mnt/hot/swapfile`, `pri=10`, `nofail`) — per your arch fstab |
| Login | **plain TTY getty → manual launch** (no DM, no graphical boot) |
| WM | niri (Void, NixOS) · **ctwm on Xorg** (Debian only) |

### NVIDIA / CUDA pins (confirmed)
- `ECJT_REPO=https://github.com/ec-jt/open-gpu-kernel-modules` → branch/tag matching **NV 610.43.02**.
- `NV_VERSION = 610.43.02` — userspace driver; **must equal the ec-jt fork tag**.
- `CUDA`: **Void pinned 13.3** (confirmed). **NixOS: 13.x** from the rolling channel. `cuDNN`+`NCCL` to match.
- **NixOS channel: `nixos-unstable`** (rolling / bleeding edge — explicitly NOT stable; `stateVersion = "26.05"` is just the schema anchor).
- **Tailnet:** `hedgehog-bortle.ts.net` → this box = `apestonks-69.hedgehog-bortle.ts.net`.

---

## Partition map (`sdc`) — all of `sdc1`–`sdc7` get a fresh filesystem

Every target partition is made fresh (clean fs + correct label/flags). The `mkfs` for each runs in the
phase that owns that partition.

| Part | Size | Role | mkfs |
|---|---|---|---|
| sdc1 | 512M | shared ESP → Debian `/boot/efi` | `mkfs.vfat -F32 -n EFI /dev/sdc1` |
| sdc2 | 768M | Debian `/boot` | `mkfs.ext4 -F -L debboot /dev/sdc2` |
| sdc3 | 1G | Void `/boot` | `mkfs.ext4 -F -L voidboot /dev/sdc3` |
| sdc4 | 1G | NixOS `/boot` | `mkfs.ext4 -F -L nixboot /dev/sdc4` |
| sdc5 | 16G | Debian `/` | `mkfs.f2fs -f -l debroot /dev/sdc5` |
| sdc6 | 107G | Void `/` | `mkfs.f2fs -f -l voidroot /dev/sdc6` |
| sdc7 | 112G | NixOS `/` (mount `compress=zstd,noatime,ssd,discard=async`) | `mkfs.btrfs -f -L 'NIX Store' /dev/sdc7` |

> Writes happen **only on `sdc`**. No other disk is written to.
>
> **Media note:** `sdc` is a **USB-bridged SSD** (Transcend ESD310C). It reports `rotational=1`, so
> btrfs won't auto-enable SSD mode → the `ssd` mount flag is set **explicitly** on `sdc7`. TRIM *does*
> pass the bridge (`DISC-MAX 4G`), so `discard=async` is safe. The f2fs/ext4 roots lean on periodic
> `fstrim` rather than continuous discard.

---

## Phase 0 — Host live prep (CachyOS / arch)

```bash
sudo pacman -S --needed arch-install-scripts dosfstools f2fs-tools btrfs-progs xfsprogs mdadm
# debootstrap is not in arch repos on the live ISO — fetch Debian's copy and run it directly:
cd /tmp && curl -fLO http://ftp.debian.org/debian/pool/main/d/debootstrap/debootstrap_<ver>_all.deb
ar x debootstrap_*.deb && tar -xf data.tar.* -C /tmp/dbs
export DEBOOTSTRAP_DIR=/tmp/dbs/usr/share/debootstrap
# (debootstrap binary: /tmp/dbs/usr/sbin/debootstrap)

# Nix (single-user, no systemd dance on a RAM live):
sh <(curl -L https://nixos.org/nix/install) --no-daemon
. ~/.nix-profile/etc/profile.d/nix.sh
nix-channel --add https://nixos.org/channels/nixos-unstable nixpkgs && nix-channel --update  # rolling / bleeding edge
nix-env -iA nixpkgs.nixos-install-tools
```

The `md0` name is set **inside each installed OS** by its `mdadm.conf` (§RAID). In the live env the
array is already assembled by the kernel — mount it where a chroot needs `/home`.

---

## Phase 1 — Debian (master) → `sdc5` + `sdc2` + shared ESP `sdc1`

```bash
mkfs.vfat -F32 -n EFI   /dev/sdc1      # shared ESP
mkfs.ext4 -F -L debboot /dev/sdc2      # Debian /boot
mkfs.f2fs -f -l debroot /dev/sdc5      # Debian /
mount /dev/disk/by-label/debroot /mnt/deb
mkdir -p /mnt/deb/boot && mount /dev/disk/by-label/debboot /mnt/deb/boot
mkdir -p /mnt/deb/boot/efi && mount /dev/disk/by-label/EFI /mnt/deb/boot/efi
/tmp/dbs/usr/sbin/debootstrap --arch=amd64 trixie /mnt/deb http://deb.debian.org/debian
for d in dev dev/pts proc sys run; do mount --rbind /$d /mnt/deb/$d; done
cp /etc/resolv.conf /mnt/deb/etc/ ; chroot /mnt/deb /bin/bash
```
Inside chroot:
- `apt install`: `linux-image-amd64 linux-headers-amd64 grub-efi-amd64 os-prober mdadm f2fs-tools sudo locales console-setup` + **net** (`systemd-resolved` + `systemd-networkd` or `network-manager`).
- Dev/common: `git curl wget jq neovim nodejs npm build-essential dkms`.
- **Xorg + ctwm (NO niri):** `xserver-xorg xinit ctwm`.
- Identity: hostname `apestonks-69`, locale `en_US.UTF-8`, **tz `America/New_York`**, keymap `us`, `passwd` root, `useradd -m -u 1000 -U -G sudo,video,render admin` (home already on shared md0 — see Phase 4).
- Bootloader (master): see **Phase 4 §Bootloader**.
- **GPU: nouveau only.** Debian is the light master — NO nvidia/CUDA/ec-jt/docker here. nouveau is
  in-kernel, nothing to install. (iGPU on default **i915** — no params, §iGPU.) `firmware-misc-nonfree` for misc fw.

## Phase 2 — Void → `sdc6` (reformat) + `sdc3`

```bash
mkfs.ext4 -F -L voidboot /dev/sdc3            # Void /boot
mkfs.f2fs -f -l voidroot /dev/sdc6            # Void /
mount /dev/disk/by-label/voidroot /mnt/void
tar xpf ~/Downloads/void-x86_64-ROOTFS-20250202.tar.xz -C /mnt/void
mkdir -p /mnt/void/boot && mount /dev/disk/by-label/voidboot /mnt/void/boot
for d in dev proc sys run; do mount --rbind /$d /mnt/void/$d; done
cp /etc/resolv.conf /mnt/void/etc/ ; chroot /mnt/void /bin/bash
```
Inside (Void uses **xbps** + **runit** + **dracut**):
- `xbps-install -Suy` then base: `base-system grub-x86_64-efi mdadm dracut f2fs-tools dbus`.
- glibc locale: edit `/etc/default/libc-locales`, `xbps-reconfigure -f glibc-locales`.
- Dev/common: `git curl wget jq neovim nodejs npm dkms`.
- **niri** (wayland): `xbps-install niri` — it's in the Void repos (same as your laptops), plus `seatd`/`elogind`, `xdg-desktop-portal-wlr`.
- **Xe iGPU (Void only):** set `xe.force_probe=a780 i915.force_probe=!a780` in `/etc/default/grub` `GRUB_CMDLINE_LINUX` before `grub-mkconfig` (§iGPU).
- Identity same as Debian (`useradd -u 1000 -G video,render,docker,wheel admin`; runit no systemd).
- Services: `ln -s /etc/sv/{dbus,seatd,tailscaled,sshd} /var/service/`.
- mdraid in initrd: `/etc/mdadm.conf` (see §RAID) + dracut `add_dracutmodules+=" mdraid "`, `xbps-reconfigure -fa`.
- Guest grub.cfg (no NVRAM entry): `grub-mkconfig -o /boot/grub/grub.cfg` (kernels land in `/boot` on sdc3).

## Phase 3 — NixOS → `sdc7` (btrfs) + `sdc4`

```bash
mkfs.ext4 -F -L nixboot      /dev/sdc4               # NixOS /boot
mkfs.btrfs -f -L 'NIX Store' /dev/sdc7               # NixOS /
mount -o compress=zstd,noatime,ssd,discard=async,space_cache=v2 /dev/disk/by-label/'NIX Store' /mnt/nix
mkdir -p /mnt/nix/boot && mount /dev/disk/by-label/nixboot /mnt/nix/boot
mkdir -p /mnt/nix/mnt/hot && mount /dev/md0 /mnt/nix/mnt/hot   # array at /mnt/hot; bind /home/admin via config
nixos-generate-config --root /mnt/nix
# edit /mnt/nix/etc/nixos/configuration.nix  (see block below)
nixos-install --root /mnt/nix
```
`configuration.nix` essentials:
```nix
networking.hostName = "apestonks-69";
system.stateVersion = "26.05";   # schema anchor only — packages track nixos-unstable, not this
boot.kernelPackages = pkgs.linuxPackages_latest;   # newest kernel: Xe (RPL) + Blackwell
time.timeZone = "America/New_York"; i18n.defaultLocale = "en_US.UTF-8"; console.keyMap = "us";
users.users.admin = { isNormalUser = true; uid = 1000;
  extraGroups = [ "wheel" "video" "render" "docker" ]; };

# Guest bootloader: write grub.cfg to OWN /boot, no NVRAM, no touching shared ESP.
boot.loader.grub = { enable = true; efiSupport = true; device = "nodev";
  efiInstallAsRemovable = false; };
boot.loader.efi.canTouchEfiVariables = false;
boot.loader.efi.efiSysMountPoint = "/boot";   # = sdc4, Debian's master grub `configfile`s this
boot.plymouth.enable = false; boot.loader.timeout = 1;   # no graphical boot

fileSystems."/".options = [ "compress=zstd" "noatime" "ssd" "discard=async" "space_cache=v2" ];  # USB SSD reports rotational=1 → ssd EXPLICIT; TRIM passes the bridge (DISC-MAX 4G)
# Array at /mnt/hot, per-user bind, nofail (matches arch fstab)
fileSystems."/mnt/hot" = { device = "/dev/disk/by-uuid/6df6919b-40b6-44bb-8c19-791c6556ae15";
  fsType = "xfs"; options = [ "rw" "strictatime" "discard" "nofail" ]; };
fileSystems."/home/admin" = { device = "/mnt/hot/home/admin"; fsType = "none";
  options = [ "bind" "nofail" ]; };
boot.swraid.enable = true;
boot.swraid.mdadmConf = "ARRAY /dev/md0 metadata=1.2 UUID=85172657:de2fb0b4:a9f5a913:98c95b5c";

# iGPU on default i915 (NO xe params on NixOS); just nvidia modeset for wayland
boot.kernelParams = [ "nvidia_drm.modeset=1" ];

# NVIDIA: userspace + cuda stack, but kernel module from ec-jt fork (see §NVIDIA stack)
hardware.nvidia.open = true;     # Blackwell is open-only; package overridden to ec-jt src
programs.niri.enable = true;     # wayland WM
services.tailscale.enable = true;
virtualisation.docker.enable = true;
hardware.nvidia-container-toolkit.enable = true;
environment.systemPackages = with pkgs; [ git curl wget jq neovim nodejs_22 nodePackages.npm bun
  cudaPackages.cudatoolkit cudaPackages.cudnn cudaPackages.nccl ];  # 13.x if channel has it, else 12.9.1 — both fine
nixpkgs.config.allowUnfree = true;
swapDevices = [ { device = "/mnt/hot/swapfile"; } ];  # shared file on the array, see §Swap
```

---

## Phase 4 — Cross-cutting wiring (applies to all three)

### §RAID — clamp `md127` → `md0` (your exact arch mdadm.conf)
- Deterministic pin by UUID (not name) — copy your arch `mdadm.conf` verbatim into each OS:
  ```
  DEVICE partitions
  HOMEHOST <system>
  MAILADDR root
  ARRAY /dev/md0 metadata=1.2 UUID=85172657:de2fb0b4:a9f5a913:98c95b5c
  ```
  Locations: Debian `/etc/mdadm/mdadm.conf` + `update-initramfs -u`; Void `/etc/mdadm.conf` + dracut
  (`mdraid` module); NixOS `boot.swraid.mdadmConf` (string below). Each initramfs must assemble the
  array (arch uses the `mdadm_udev` hook — Debian/Void/NixOS equivalents handle this).
- **Matches your arch fstab convention:** array mounts at **`/mnt/hot`**, you **bind per-user** dirs
  out of it, `nofail` so a dead array never blocks boot. Every OS's fstab (keyed by UUID like you do):
  ```
  UUID=6df6919b-40b6-44bb-8c19-791c6556ae15  /mnt/hot      xfs   rw,strictatime,discard,nofail  0 2
  /mnt/hot/home/admin                        /home/admin   none  bind,nofail                    0 0
  ```
  (Add more `/mnt/hot/home/<user>` binds later, same pattern — and deferred `/var` binds too.)
- **Fallback semantics (what you described):** `/home/admin` is a real local dir on each USB rootfs.
  Array up → `/mnt/hot/home/admin` binds over it. Array dead → bind skips (`nofail`) → you fall back
  to the **local `/home/admin`** on the rootfs; boot/login unaffected. So each rootfs must already
  contain `/home/admin` (guaranteed by `useradd -m admin` / NixOS `isNormalUser`).

### §`/var/lib` offload — bind the heavy `/var/lib/*` onto the array (so you don't redo it per install)
The space-eaters live under `/var/lib`; bind each onto `/mnt/hot` so they never fill the small USB roots
**and persist across reinstalls**. Same `nofail` bind pattern as `/home`. Make the targets first:
`mkdir -p /mnt/hot/var/{docker,containers,machines,libvirt,ollama}`.

Debian/Void fstab (add only the ones that OS actually runs):
```
/mnt/hot/var/docker      /var/lib/docker      none  bind,nofail  0 0   # docker images/overlay
/mnt/hot/var/containers  /var/lib/containers  none  bind,nofail  0 0   # podman
/mnt/hot/var/machines    /var/lib/machines    none  bind,nofail  0 0   # systemd-nspawn
/mnt/hot/var/libvirt     /var/lib/libvirt     none  bind,nofail  0 0   # kvm/qemu VM images
/mnt/hot/var/ollama      /var/lib/ollama      none  bind,nofail  0 0   # ollama models (huge)
```

NixOS equivalent (no fstab — declare in `configuration.nix`, since this isn't your dept):
```nix
fileSystems."/var/lib/docker"  = { device = "/mnt/hot/var/docker";  fsType = "none"; options = [ "bind" "nofail" ]; };
fileSystems."/var/lib/libvirt" = { device = "/mnt/hot/var/libvirt"; fsType = "none"; options = [ "bind" "nofail" ]; };
fileSystems."/var/lib/ollama"  = { device = "/mnt/hot/var/ollama";  fsType = "none"; options = [ "bind" "nofail" ]; };
# add /var/lib/{containers,machines} the same way if used
```
`nofail` everywhere → dead array just falls back to the local (empty) dir, never blocks boot. (Whole-`/var`
on the array stays deferred/optional per your call — this is only the `/var/lib` heavyweights.)

### §Swap — single shared swapfile on the array (matches your arch fstab)
- One swapfile on `/mnt/hot` (your convention), referenced by all three. Safe because only one distro
  boots at a time off USB; and Debian's 16G root can't host a swapfile anyway.
- Create once (on the xfs raid): `dd if=/dev/zero of=/mnt/hot/swapfile bs=1M count=16384`
  (NOT fallocate — swap needs no holes); `chmod 600; mkswap /mnt/hot/swapfile`.
- Each OS fstab: `/mnt/hot/swapfile  none  swap  defaults,pri=10,nofail  0 0`
  (`nofail` so a dead array drops swap but never blocks boot — consistent with the `/home` policy).
- NixOS: `swapDevices = [ { device = "/mnt/hot/swapfile"; } ];` (no `size` — file already exists on xfs).

### §Bootloader — Debian GRUB is master, chainloads guests
- In Debian chroot:
  `grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck`
- `/etc/default/grub`: `GRUB_DISABLE_OS_PROBER=false`, `GRUB_TIMEOUT=2`, **no** `splash`/`quiet`-graphics, set `GRUB_GFXPAYLOAD_LINUX=text` (no graphical boot).
- `/etc/grub.d/40_custom` — explicit, reliable chainload (don't rely on os-prober alone):
  ```
  menuentry "Void Linux" { search --no-floppy --label voidboot --set=root; configfile /grub/grub.cfg }
  menuentry "NixOS"      { search --no-floppy --label nixboot  --set=root; configfile /grub/grub.cfg }
  ```
- `update-grub`. Verify `efibootmgr` lists `debian` first (rEFInd Boot0006 stays as harmless fallback).
- Void/NixOS write their own `/boot/grub/grub.cfg` (Phases 2/3) but **never** an NVRAM entry.

### §iGPU driver — i915 on Debian+NixOS, **Xe on Void only**
- **Debian + NixOS:** default **i915** (RPL-S supported natively — no kernel params needed).
- **Void only** ("the weird child"): force **Xe** via kernel cmdline in Void's `GRUB_CMDLINE_LINUX`:
  `xe.force_probe=a780 i915.force_probe=!a780`
  Needs a kernel new enough for `xe` to bind RPL-S (Void's current kernel qualifies; if not, hold).

### §NVIDIA stack — **Void + NixOS ONLY** (Debian = nouveau, skip entirely)
Userspace + CUDA + cuDNN + NCCL + docker + nvidia-container-toolkit on **Void & NixOS**;
**the kernel module comes from `ec-jt/open-gpu-kernel-modules`** (P2P fork), built per-OS.
Debian renders on nouveau (iGPU via Xe) and never touches this section.

- **Why built in-OS / via DKMS:** a module links against its kernel → must be built against
  *each OS's* kernel, not this live one. DKMS rebuilds against the installed kernel's headers
  automatically (works at install time; doesn't need that kernel running). Manual fallback:
  boot the OS, then build against the running kernel.

- **Per distro:**
  - **Void:** `nvidia` userspace (v610.43.02) via repo/runfile `--no-kernel-modules`; **CUDA 13.3** +
    cuDNN + NCCL via NVIDIA repo/runfile (known-good on your Void laptops); `docker nvidia-container-toolkit`.
  - **NixOS:** `hardware.nvidia.open = true` + override `hardware.nvidia.package` so `src` = ec-jt
    fork at the chosen tag (open modules built from that source); `cudaPackages.{cudatoolkit,cudnn,nccl}`.

- **ec-jt module build (Deb/Void), as DKMS:**
  ```bash
  git clone https://github.com/ec-jt/open-gpu-kernel-modules /usr/src/ecjt-<ver>
  cd /usr/src/ecjt-<ver> && git checkout <tag-matching-NV_VERSION>
  # ship a dkms.conf (PACKAGE_NAME=ecjt-open, BUILT_MODULE from kernel-open) then:
  dkms add -m ecjt-open -v <ver>
  dkms install -m ecjt-open -v <ver> -k $(uname -r)   # or target installed kernel ver
  depmod -a
  ```
  Manual one-liner fallback (after booting the OS): `make modules -j && make modules_install && depmod -a`.

- **P2P prerequisites (BIOS):** Above-4G Decoding **on**, Resizable BAR **on** — required for
  5060 Ti↔5060 Ti P2P with the patched modules. Verify post-boot with `nvidia-smi topo -p2p r`.

### §Shared `/home` freebies
- Because `/home` (md0) is mounted on all three with the same UID 1000, **per-user installs are
  shared** → install **bun once** as `admin`: `curl -fsSL https://bun.sh/install | bash`
  (lands in `/home/admin/.bun`, visible from all three). Same for nvim config, git config, etc.

### §Tailscale — all three
- Debian: tailscale apt repo → `tailscale`; Void: `xbps-install tailscale` + runit service;
  NixOS: `services.tailscale.enable`. `tailscale up --hostname apestonks-69` → joins tailnet
  **`hedgehog-bortle.ts.net`** as `apestonks-69.hedgehog-bortle.ts.net`.

---

## Verification (after each OS first-boots)

1. **Boot menu:** reboot → Debian GRUB shows Debian + **Void** + **NixOS**; each boots to a TTY login (no graphics).
2. **Identity:** `hostnamectl` = `apestonks-69`; `id admin` = uid/gid 1000; `/home/admin` is the same files on all three.
3. **RAID:** `cat /proc/mdstat` shows **`md0`** (not md127); `findmnt /mnt/hot` = `/dev/md0` xfs;
   `findmnt /home/admin` shows the `bind`. Then test fallback: boot with array absent → still reaches
   login, `/home/admin` is the local rootfs copy.
4. **iGPU:** `lspci -k -s 00:02.0` → driver **`i915`** on Debian+NixOS, **`xe`** on Void only.
5. **Debian dGPU:** `lspci -k -s 01:00.0` → driver **`nouveau`** (no nvidia/cuda expected on Debian).
6. **Void/Nix dGPU + P2P:** `nvidia-smi` lists both 5060 Ti; `modinfo nvidia | grep -i version` = NV_VERSION;
   `lsmod | grep nvidia` loaded from ec-jt build; `nvidia-smi topo -p2p r` shows **P2P OK** between GPUs.
7. **Void/Nix CUDA dev:** `nvcc --version` → **Void 13.3**, **NixOS 13.x or 12.9.1** (both fine); build/run a tiny CUDA sample; NCCL allreduce across 2 GPUs succeeds.
   `docker run --rm --gpus all <cuda-image> nvidia-smi` works (nvidia-ctk wired).
8. **Real-workload proof (the actual goal):** `nvidia-smi topo -p2p r` = P2P OK both directions, then
   **vLLM tensor-parallel (TP=2)** serving Gemma 4 31B dense hits your ~75 T/s tg. If P2P silently
   fell back (ReBAR/Above-4G off, or ec-jt tag ≠ 610.43.02), TP throughput craters — that's the canary.
9. **Swap:** `swapon --show` shows the 16G file on each.
10. **WM:** Void/NixOS launch `niri` from TTY; Debian `startx` → ctwm.
11. **Tailscale:** `tailscale status` up; box is `apestonks-69.hedgehog-bortle.ts.net`.

## Known rough edges (flagged, not blockers)
- **ec-jt tag must == NV 610.43.02** — confirm before building; userspace driver version must match exactly.
- **NixOS CUDA**: on `nixos-unstable`, `cudaPackages` 13.x is current — 12.9.1 fallback shouldn't be needed.
- **Void CUDA 13.3** via NVIDIA repo/runfile (not native xbps pkgs) — known-good for you, just not one-command.
- **os-prober** is a backup; the explicit `configfile` entries are the primary chainload path.
