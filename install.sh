#!/usr/bin/env bash
# apestonks-69 triple-boot installer — Debian (master) + Void + NixOS onto USB SSD /dev/sdc.
# Run as root from a vfat-capable live env. REVIEW FIRST: this formats ALL of sdc (sdc1-7).
# Pairs with PLAN.md. Mechanical parts automated; the two FILL-INs are nvidia-only.
set -euo pipefail

### ── set these ──────────────────────────────────────────────────────────────
DISK=/dev/sdc
DEB_SUITE=trixie
HOME_XFS_UUID=6df6919b-40b6-44bb-8c19-791c6556ae15
MDADM_UUID=85172657:de2fb0b4:a9f5a913:98c95b5c
VOID_TARBALL="$HOME/Downloads/void-x86_64-ROOTFS-20250202.tar.xz"
ECJT_REPO=https://github.com/ec-jt/open-gpu-kernel-modules
ECJT_TAG=__FILL_ME__          # tag matching NV 610.43.02   (nvidia-only; not needed to boot)
NV_VERSION=610.43.02
### ───────────────────────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }
echo "About to FORMAT every partition on $DISK (sdc1-7). md0/your raid is NEVER touched."
read -rp "Type YES to proceed: " a; [[ $a == YES ]] || exit 1

MDADM_CONF=$'DEVICE partitions\nHOMEHOST <system>\nMAILADDR root\nARRAY /dev/md0 metadata=1.2 UUID='"$MDADM_UUID"
ARRAY_FSTAB=$'UUID='"$HOME_XFS_UUID"$'  /mnt/hot      xfs   rw,strictatime,discard,nofail  0 2\n/mnt/hot/home/admin                        /home/admin   none  bind,nofail                    0 0\n/mnt/hot/swapfile                          none          swap  defaults,pri=10,nofail         0 0'

bind_api() { for d in dev dev/pts proc sys run; do mount --rbind "/$d" "$1/$d"; done; cp /etc/resolv.conf "$1/etc/"; }

phase0_host() {
  pacman -S --needed --noconfirm arch-install-scripts dosfstools f2fs-tools btrfs-progs xfsprogs mdadm mtools curl
  mkdir -p /tmp/dbs && cd /tmp
  # debootstrap + Debian keyring (Arch has neither; without the keyring GPG-verify fails)
  base=http://ftp.debian.org/debian/pool/main/d
  for u in "$base/debootstrap/" "$base/debian-archive-keyring/"; do
    f=$(curl -fsSL "$u" | grep -oE '(debootstrap|debian-archive-keyring)_[^"]*_all\.deb' | sort -V | tail -1)
    curl -fLO "$u$f"
  done
  for deb in debootstrap_*_all.deb debian-archive-keyring_*_all.deb; do ar x "$deb"; tar -xf data.tar.*; done
  cp -a usr /tmp/dbs/ 2>/dev/null || tar -xf data.tar.* -C /tmp/dbs
  export DEBOOTSTRAP_DIR=/tmp/dbs/usr/share/debootstrap
  mdadm --assemble --scan || true            # mount the existing array as-is (node may be md127 here)
}

phase1_debian() {
  mkfs.vfat -F32 -n EFI   "${DISK}1"
  mkfs.ext4 -F  -L debboot "${DISK}2"
  mkfs.f2fs -f  -l debroot "${DISK}5"
  mount /dev/disk/by-label/debroot /mnt/deb
  mkdir -p /mnt/deb/boot && mount /dev/disk/by-label/debboot /mnt/deb/boot
  mkdir -p /mnt/deb/boot/efi && mount /dev/disk/by-label/EFI /mnt/deb/boot/efi
  /tmp/dbs/usr/sbin/debootstrap --arch=amd64 \
    --keyring=/tmp/dbs/usr/share/keyrings/debian-archive-keyring.gpg --include=debian-archive-keyring \
    "$DEB_SUITE" /mnt/deb http://deb.debian.org/debian
  bind_api /mnt/deb
  printf '%s\n' "$MDADM_CONF" > /mnt/deb/etc/mdadm/mdadm.conf 2>/dev/null || { mkdir -p /mnt/deb/etc/mdadm; printf '%s\n' "$MDADM_CONF" > /mnt/deb/etc/mdadm/mdadm.conf; }
  cat > /mnt/deb/root/setup.sh <<DEBEOF
set -euo pipefail
echo apestonks-69 > /etc/hostname
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen; locale-gen; echo LANG=en_US.UTF-8 > /etc/locale.conf
apt-get update
apt-get install -y linux-image-amd64 linux-headers-amd64 grub-efi-amd64 os-prober mdadm f2fs-tools \\
  sudo locales console-setup network-manager git curl wget jq neovim nodejs npm build-essential dkms \\
  xserver-xorg xinit ctwm firmware-misc-nonfree
useradd -m -u 1000 -U -G sudo,video,render admin
echo "set admin/root passwords:"; passwd admin; passwd root
# fstab: own boot/efi + array binds + swap
cat >> /etc/fstab <<FSTAB
LABEL=debroot  /          f2fs  defaults,noatime  0 1
LABEL=debboot  /boot      ext4  defaults          0 2
LABEL=EFI      /boot/efi  vfat  umask=0077        0 2
$ARRAY_FSTAB
FSTAB
update-initramfs -u
# master GRUB + chainload Void/NixOS
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck
sed -i 's/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
echo 'GRUB_GFXPAYLOAD_LINUX=text' >> /etc/default/grub
cat >> /etc/grub.d/40_custom <<'CUST'
menuentry "Void Linux" { search --no-floppy --label voidboot --set=root; configfile /grub/grub.cfg }
menuentry "NixOS"      { search --no-floppy --label nixboot  --set=root; configfile /grub/grub.cfg }
CUST
update-grub
DEBEOF
  chroot /mnt/deb /bin/bash /root/setup.sh
}

phase2_void() {
  mkfs.ext4 -F -L voidboot "${DISK}3"
  mkfs.f2fs -f -l voidroot "${DISK}6"
  mount /dev/disk/by-label/voidroot /mnt/void
  tar xpf "$VOID_TARBALL" -C /mnt/void
  mkdir -p /mnt/void/boot && mount /dev/disk/by-label/voidboot /mnt/void/boot
  bind_api /mnt/void
  printf '%s\n' "$MDADM_CONF" > /mnt/void/etc/mdadm.conf
  cat > /mnt/void/setup.sh <<VOIDEOF
set -euo pipefail
xbps-install -Suy xbps            # old rootfs: update xbps itself first (separate transaction)
xbps-install -uy
xbps-install -y base-system grub-x86_64-efi mdadm dracut f2fs-tools dbus seatd elogind \\
  git curl wget jq neovim nodejs npm dkms niri xdg-desktop-portal-wlr tailscale
echo apestonks-69 > /etc/hostname
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/default/libc-locales; xbps-reconfigure -f glibc-locales
useradd -m -u 1000 -U -G wheel,video,render,docker admin || true
echo "set admin/root passwords:"; passwd admin; passwd root
cat >> /etc/fstab <<FSTAB
LABEL=voidroot  /      f2fs  defaults,noatime  0 1
LABEL=voidboot  /boot  ext4  defaults          0 2
$ARRAY_FSTAB
FSTAB
echo 'GRUB_CMDLINE_LINUX="xe.force_probe=a780 i915.force_probe=!a780"' >> /etc/default/grub
echo 'add_dracutmodules+=" mdraid "' > /etc/dracut.conf.d/mdraid.conf
ln -sf /etc/sv/{dbus,seatd,tailscaled} /var/service/ || true
xbps-reconfigure -fa
grub-mkconfig -o /boot/grub/grub.cfg
# nvidia/CUDA + ec-jt: see install_nvidia note in PLAN.md (driver $NV_VERSION, repo $ECJT_REPO @ $ECJT_TAG)
VOIDEOF
  chroot /mnt/void /bin/bash /setup.sh
}

phase3_nixos() {
  mkfs.ext4 -F -L nixboot "${DISK}4"
  mkfs.btrfs -f -L 'NIX Store' "${DISK}7"
  mount -o compress=zstd,noatime,ssd,discard=async,space_cache=v2 /dev/disk/by-label/'NIX Store' /mnt/nix
  mkdir -p /mnt/nix/boot && mount /dev/disk/by-label/nixboot /mnt/nix/boot
  mkdir -p /mnt/nix/mnt/hot && mount /dev/md0 /mnt/nix/mnt/hot 2>/dev/null || mount /dev/md127 /mnt/nix/mnt/hot
  nixos-generate-config --root /mnt/nix
  # flake.nix + configuration.nix come from PLAN.md (Phase 3). Drop them into /mnt/nix/etc/nixos/ then:
  echo ">>> Write flake.nix + configuration.nix per PLAN.md into /mnt/nix/etc/nixos/, fill nvidia.package, then:"
  echo "    nixos-install --root /mnt/nix --flake /mnt/nix/etc/nixos#apestonks-69 --option experimental-features 'nix-command flakes'"
}

mkdir -p /mnt/{deb,void,nix}
phase0_host
phase1_debian
phase2_void
phase3_nixos
echo "Done with mechanical parts. nvidia/ec-jt build + NixOS flake install are the remaining manual steps (PLAN.md)."
