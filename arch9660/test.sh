#!/usr/bin/env bash
#
# Build an archiso
set -e

prepare() {
  local pkg_strap_dir="${1}"
  local cfg="${2}"
  local erofsdir="${3}"

  mkdir -p "${pkg_strap_dir}" "${erofsdir}"
  cp -Ta "${cfg}" "${pkg_strap_dir}"

  cp "${cfg}/etc/pacman.conf" /etc
  pacman -Syu arch-install-scripts mtools python xorriso dosfstools \
    erofs-utils --noconfirm
}

pkg_strap() {
  local pkg_strap_dir="${1}"

  pacstrap -cG "${pkg_strap_dir}" amd-ucode base bash-completion \
    linux-hardened linux-firmware-{broadcom,realtek} gptfdisk mkinitcpio \
    mkinitcpio-archiso python arch-install-scripts reflector btrfs-progs \
    dosfstools iwd iptables-nft xfsprogs less nano zram-generator &>/dev/null
}

configure_system() {
  local pkg_strap_dir="${1}"
  local uuid="${2}"

  ln -svf /usr/share/zoneinfo/UTC "${pkg_strap_dir}/etc/localtime"
  ln -svf /usr/local/bin/arch39 "${pkg_strap_dir}/usr/local/bin/arch-install"
  ln -svf /dev/null \
    "${pkg_strap_dir}/etc/systemd/system/systemd-networkd-wait-online.service"

  date '+arch%d-%m-%y' > "${pkg_strap_dir}/etc/hostname"
  sed -i "s/<UUID>/${uuid}/" \
    "${pkg_strap_dir}/boot/loader/entries/arch9660-hardened.conf"

  chmod -R 755 "${pkg_strap_dir}/usr/local/bin"
  chmod 400 "${pkg_strap_dir}/etc/shadow"
}

make_esp() {
  local pkg_strap_dir="${1}"

  rm -f -- "${pkg_strap_dir}/boot/amd-ucode.img"
  local bootsize
  bootsize="$(($(du -B1024 -s "${pkg_strap_dir}/boot" | awk '{print $1}') + 512))"

  mkfs.fat -F32 -S512 -R2 -v -f1 -s1 -b0 -n 'ESP9660' \
    --codepage=437 -C /var/esp.img "${bootsize}"

  # mkdir inside esp img
  mmd -i /var/esp.img '::/loader' '::/loader/entries' '::/EFI' '::/EFI/BOOT'

  # Copy files to esp img
  mcopy -i /var/esp.img "${pkg_strap_dir}/boot/loader/loader.conf" '::/loader'
  mcopy -i /var/esp.img \
    "${pkg_strap_dir}/boot/loader/entries/arch9660-hardened.conf" \
    '::/loader/entries'
  mcopy -i /var/esp.img \
    "${pkg_strap_dir}/usr/lib/systemd/boot/efi/systemd-bootx64.efi" \
    '::/EFI/BOOT/BOOTX64.EFI'
  mcopy -i /var/esp.img \
    "${pkg_strap_dir}/boot/initramfs-linux-hardened.img}" '::/'
  mcopy -i /var/esp.img \
    "${pkg_strap_dir}/boot/vmlinuz-linux-hardened" '::/'
}

cleanup() {
  local pkg_strap_dir="${1}"

  local modpath
  modpath=$(realpath "${pkg_strap_dir}/usr/lib/modules/"*)

  rm -rf -- "${pkg_strap_dir}/"{boot,var/tmp,var/log,tmp}/* \
    "${pkg_strap_dir}/var/cache/pacman/pkg/"* \
    "${pkg_strap_dir}/var/lib/pacman/sync/"* \
    "${modpath}/kernel/drivers/sound" \
    "${pkg_strap_dir}/usr/share/"{gtk-doc,gir-1.0,man} \
    "${pkg_strap_dir}/usr/include" "${pkg_strap_dir}/usr/lib/libgo."*

  find "${pkg_strap_dir}" \( -name '*.pacnew' \
    -o -name '*.pacsave' -o -name '*.pacorig' \) -delete
  find "${pkg_strap_dir}/var/lib/pacman" \
    -maxdepth 1 -type f -delete
}

compress_airootfs() {
  local pkg_strap_dir="${1}"
  local erofsdir="${2}"

  echo '- Compressing EROFS...'
  mkfs.erofs --quiet -L 'arch9660' \
    -E'fragments,fragdedupe=full,force-inode-extended,ztailpacking' -T0 \
    -z'lzma',109,dictsize=8388608 -C1048576 "${erofsdir}/airootfs.erofs" \
    "${pkg_strap_dir}"
}

make_isofile() {
  local erofsdir="${1}"
  local uuid="${2}"

  xorriso -no_rc -volume_date uuid "${uuid}" -temp_mem_limit 1024m \
    -as mkisofs -iso-level 2 -rational-rock -volid 'ARCH9660' \
    -appid 'arch9660' -preparer 'prepared by arch9660' \
    -publisher 'Arch9660 <https://github.com/nedorazrab0/arch9660>' \
    -appended_part_as_gpt -partition_offset 16 -no-pad \
    -append_partition 2 '0xEF' "/var/esp.img" \
    -eltorito-alt-boot -e --interval:appended_partition_2:all:: \
    -no-emul-boot -output /var/arch9660.iso "${erofsdir}"
}

main() {
  local cfg='/var/arch9660/cfg'
  local pkg_strap_dir='/var/arch9660/pkg_strap_dir'
  local erofsdir='/var/arch9660/erofsdir'
  #imgdir='/var/arch9660/img'

  prepare "${pkg_strap_dir}" "${cfg}" "${erofsdir}"

  local uuid
  uuid="$(python3 /var/arch9660/generate_fucking_xorriso_uuid)"

  pkg_strap "${pkg_strap_dir}"
  configure_system "${pkg_strap_dir}" "${uuid}"
  make_esp "${pkg_strap_dir}"
  cleanup "${pkg_strap_dir}"
  compress_airootfs "${pkg_strap_dir}" "${erofsdir}"
  make_isofile "${erofsdir}" "${uuid}"
}

main

ls -lh "/var/arch9660.iso"
blkid "/var/arch9660.iso"
