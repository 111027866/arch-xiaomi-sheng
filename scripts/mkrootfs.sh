#!/usr/bin/env bash
# Assemble a flashable Arch Linux ARM rootfs and Android boot image.

set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/packages.sh
source "$SCRIPTS_DIR/lib/packages.sh"

MOUNT_DIR=""

usage() {
  cat <<'EOF'
用法: mkrootfs.sh [选项]

选项:
  --desktop none|kde|gnome|denial
  --extra "PKG ..."
  --hostname NAME
  --user NAME
  --password PASSWORD
  --size MIB
  --fs ext4|btrfs
  --partlabel LABEL
  --cmdline "KERNEL COMMAND LINE"
  -h, --help
EOF
}

while (($# > 0)); do
  case "$1" in
    --desktop)
      require_option_value "$1" "${2:-}"
      ROOTFS_DESKTOP="$2"
      shift 2
      ;;
    --extra)
      require_option_value "$1" "${2:-}"
      ROOTFS_EXTRA_PKGS="$2"
      shift 2
      ;;
    --hostname)
      require_option_value "$1" "${2:-}"
      ROOTFS_HOSTNAME="$2"
      shift 2
      ;;
    --user)
      require_option_value "$1" "${2:-}"
      ROOTFS_USER="$2"
      shift 2
      ;;
    --password)
      require_option_value "$1" "${2:-}"
      ROOTFS_PASSWORD="$2"
      shift 2
      ;;
    --size)
      require_option_value "$1" "${2:-}"
      ROOTFS_SIZE_MB="$2"
      shift 2
      ;;
    --fs)
      require_option_value "$1" "${2:-}"
      ROOTFS_FS="$2"
      shift 2
      ;;
    --partlabel)
      require_option_value "$1" "${2:-}"
      ROOTFS_PARTLABEL="$2"
      ROOTFS_KERNEL_CMDLINE="root=PARTLABEL=${ROOTFS_PARTLABEL} rw rootwait"
      shift 2
      ;;
    --cmdline)
      require_option_value "$1" "${2:-}"
      ROOTFS_KERNEL_CMDLINE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数: $1（使用 --help 查看帮助）"
      ;;
  esac
done

cleanup() {
  if [[ -n "$MOUNT_DIR" ]] && mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
    warn "清理挂载点: $MOUNT_DIR"
    sudo umount -R "$MOUNT_DIR" || true
  fi
  [[ -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]] || rmdir "$MOUNT_DIR" 2>/dev/null || true
}
trap cleanup EXIT

desktop_packages() {
  case "$ROOTFS_DESKTOP" in
    kde)
      printf '%s\n' libksysguard ksystemstats plasma-meta konsole dolphin plasma-nm plasma-pa \
        kscreen powerdevil spectacle gwenview sddm
      ;;
    gnome)
      printf '%s\n' gnome gnome-tweaks gdm networkmanager
      ;;
    denial)
      # Denial 自带 wayland-session 入口；SDDM 负责登录与自动登录。
      printf '%s\n' denial sddm networkmanager
      ;;
    none)
      ;;
    *)
      die "不支持的桌面: $ROOTFS_DESKTOP（可选 none、kde、gnome、denial）"
      ;;
  esac
}

denial_enabled() {
  [[ "$ROOTFS_DESKTOP" == denial ]]
}

configure_denial_repository() {
  # arch-chroot 会在目标 /tmp 上挂 tmpfs，写到镜像 /tmp 的密钥在 chroot 内看不到；
  # 放在 /root 下，两边路径一致。
  local key_path="/root/denial-repo-key.asc"
  local key_file="$MOUNT_DIR$key_path"
  local fingerprint

  [[ -f "$MOUNT_DIR/etc/pacman.d/gnupg/trustdb.gpg" || \
     -f "$MOUNT_DIR/etc/pacman.d/gnupg/pubring.kbx" ]] || \
    die "pacman keyring 未初始化，无法信任 Denial 仓库密钥"

  msg "配置 Denial 软件源: $ROOTFS_DENIAL_REPO"
  sudo curl -fsSL --retry 3 --connect-timeout 20 \
    -o "$key_file" "$ROOTFS_DENIAL_KEY_URL"

  # pacman-key 依赖完整的 GnuPG 环境，base 组不保证包含 gnupg。
  sudo arch-chroot "$MOUNT_DIR" pacman -S --needed --noconfirm gnupg

  fingerprint="$(sudo arch-chroot "$MOUNT_DIR" gpg --batch --with-colons \
    --show-keys "$key_path" |
    awk -F: '$1 == "fpr" { print toupper($10); exit }')"
  [[ "$fingerprint" == "$ROOTFS_DENIAL_KEY_FINGERPRINT" ]] || \
    die "Denial 仓库密钥指纹不匹配: ${fingerprint:-<空>}"

  sudo arch-chroot "$MOUNT_DIR" pacman-key --add "$key_path"
  sudo arch-chroot "$MOUNT_DIR" \
    pacman-key --lsign-key "$ROOTFS_DENIAL_KEY_FINGERPRINT"
  sudo rm -f "$key_file"

  printf '\n[denial]\nSigLevel = Required TrustedOnly\nServer = %s\n' \
    "$ROOTFS_DENIAL_REPO" | sudo tee -a "$MOUNT_DIR/etc/pacman.conf" >/dev/null
}

configure_denial_session() {
  msg "配置 Denial 会话（shell profile: $ROOTFS_DENIAL_PROFILE）"
  printf '\n# Added by arch-xiaomi-sheng: Denial shell profile (desktop/mobile).\nDENIAL_SHELL_PROFILE=%s\n' \
    "$ROOTFS_DENIAL_PROFILE" |
    sudo tee -a "$MOUNT_DIR/etc/denial/session.conf" >/dev/null

  # SDDM 已认证用户，因此会话按解锁状态启动；若改用 getty/greetd 自动登录，
  # 必须改为 denial-session --start-locked。
  if [[ -n "$ROOTFS_USER" ]]; then
    sudo install -d -m 0755 "$MOUNT_DIR/etc/sddm.conf.d"
    cat <<EOF | sudo tee "$MOUNT_DIR/etc/sddm.conf.d/10-autologin.conf" >/dev/null
[Autologin]
User=$ROOTFS_USER
Session=denial
Relogin=false
EOF
  fi
}

validate_options() {
  [[ "$ROOTFS_SIZE_MB" =~ ^[0-9]+$ ]] || die "--size 必须是整数 MiB"
  ((ROOTFS_SIZE_MB >= 2048)) || die "rootfs 镜像至少需要 2048 MiB"
  [[ "$ROOTFS_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die "主机名格式无效"
  [[ -z "$ROOTFS_USER" || "$ROOTFS_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "用户名格式无效"
  [[ "$ROOTFS_PARTLABEL" =~ ^[a-zA-Z0-9._-]+$ ]] || die "分区标签格式无效"
  [[ "$ROOTFS_FS" == ext4 || "$ROOTFS_FS" == btrfs ]] || \
    die "ROOTFS_FS 只能是 ext4 或 btrfs"
  if denial_enabled; then
    [[ "$ROOTFS_DENIAL_PROFILE" == mobile || "$ROOTFS_DENIAL_PROFILE" == desktop ]] || \
      die "ROOTFS_DENIAL_PROFILE 只能是 mobile 或 desktop"
    [[ "$ROOTFS_DENIAL_KEY_FINGERPRINT" =~ ^([0-9A-F]{40})$ ]] || \
      die "ROOTFS_DENIAL_KEY_FINGERPRINT 必须是 40 位大写十六进制指纹"
  fi
  desktop_packages >/dev/null
}

verify_filesystem() {
  local image="$1"
  local status

  set +e
  case "$ROOTFS_FS" in
    ext4) e2fsck -fp "$image" ;;
    btrfs) btrfs check --readonly "$image" ;;
  esac
  status=$?
  set -e

  case "$ROOTFS_FS" in
    ext4) ((status <= 1)) || die "文件系统检查失败，e2fsck 状态码: $status" ;;
    btrfs) ((status == 0)) || die "文件系统检查失败，btrfs check 状态码: $status" ;;
  esac
}

main() {
  local rootfs_image="$OUT_ROOTFS_DIR/rootfs.img"
  local boot_image="$OUT_ROOTFS_DIR/boot.img"
  local repository_in_rootfs
  local -a desktop_pkgs=()
  local -a extra_pkgs=()
  local -a repository_files=()
  local -a base_pkgs=(
    alsa-utils
    base
    networkmanager
    rtkit
    sudo
    vim
    wireless-regdb
  )

  validate_options
  if [[ "$ROOTFS_FS" == btrfs ]]; then
    base_pkgs+=(btrfs-progs)
  fi
  local -a fs_commands=()
  case "$ROOTFS_FS" in
    ext4) fs_commands=(e2fsck mkfs.ext4) ;;
    btrfs) fs_commands=(btrfs mkfs.btrfs) ;;
  esac
  require_commands arch-chroot awk chpasswd cp find install \
    mount mountpoint pacstrap sed sudo tee truncate umount "${fs_commands[@]}"
  if denial_enabled; then
    require_commands curl
  fi

  [[ -d "$OUT_REPO_DIR" ]] || die "本地仓库不存在；请先运行 make repo"
  mapfile -t repository_files < <(
    find "$OUT_REPO_DIR" -maxdepth 1 \( -type f -o -type l \) -print | sort
  )
  ((${#repository_files[@]} > 0)) || die "本地仓库为空: $OUT_REPO_DIR"
  [[ -e "$OUT_REPO_DIR/sheng.db" ]] || die "仓库数据库缺失: $OUT_REPO_DIR/sheng.db"

  mkdir -p "$OUT_ROOTFS_DIR"
  rm -f "$boot_image"
  truncate -s 0 "$rootfs_image"
  truncate -s "${ROOTFS_SIZE_MB}M" "$rootfs_image"
  msg "创建 $ROOTFS_FS 文件系统"
  case "$ROOTFS_FS" in
    ext4) mkfs.ext4 -F -L sheng-root "$rootfs_image" ;;
    btrfs)
      local -a btrfs_features=()
      [[ -z "$ROOTFS_BTRFS_FEATURES" ]] || \
        btrfs_features=(-O "$ROOTFS_BTRFS_FEATURES")
      mkfs.btrfs -f "${btrfs_features[@]}" -L sheng-root "$rootfs_image"
      ;;
  esac

  MOUNT_DIR="$(mktemp -d)"
  msg "挂载 rootfs: $MOUNT_DIR"
  sudo mount -o loop "$rootfs_image" "$MOUNT_DIR"

  # Do not install the generic kernel/firmware: project packages provide the
  # device-specific replacements and would otherwise conflict in pacman.
  # Do not pass -K: that initialises an *empty* keyring in the target and every
  # package then fails verification with "signature is unknown trust"; without
  # it pacstrap copies the host keyring, which is what a normal install does.
  msg "安装 Arch Linux ARM 基础系统"
  sudo pacstrap "$MOUNT_DIR" "${base_pkgs[@]}"

  repository_in_rootfs="$MOUNT_DIR/opt/sheng-repo"
  sudo install -d -m 0755 "$repository_in_rootfs"
  sudo cp -a -- "${repository_files[@]}" "$repository_in_rootfs/"
  # Insert sheng before the distribution repositories. Several project
  # packages intentionally override packages with the same official name
  # (notably iio-sensor-proxy), and pacman resolves ties by repository order.
  awk '
    function print_sheng() {
      print ""
      print "[sheng]"
      print "SigLevel = Never"
      print "Server = file:///opt/sheng-repo"
    }
    !inserted && /^\[[^]]+\]$/ && $0 != "[options]" {
      print_sheng()
      inserted = 1
    }
    { print }
    END {
      if (!inserted) print_sheng()
    }
  ' "$MOUNT_DIR/etc/pacman.conf" | \
    sudo tee "$MOUNT_DIR/etc/pacman.conf.new" >/dev/null
  sudo mv "$MOUNT_DIR/etc/pacman.conf.new" "$MOUNT_DIR/etc/pacman.conf"

  msg "安装 ${#ROOTFS_PACKAGES[@]} 个 sheng 核心硬件支持包"
  # Suppress post hooks during the package transaction. The boot entry does
  # not exist yet, and running a flashing hook from a mounted build image is
  # unsafe. A final, explicitly non-flashing mkinitcpio run happens below.
  sudo arch-chroot "$MOUNT_DIR" /usr/bin/env MKINITCPIO_POST_HOOKS=/dev/null \
    pacman -Syu --noconfirm -- "${ROOTFS_PACKAGES[@]}"

  if denial_enabled; then
    configure_denial_repository
    msg "刷新软件源索引（含 Denial）"
    sudo arch-chroot "$MOUNT_DIR" pacman -Sy --noconfirm
  fi

  mapfile -t desktop_pkgs < <(desktop_packages)
  if ((${#desktop_pkgs[@]} > 0)); then
    msg "安装桌面环境: $ROOTFS_DESKTOP"
    sudo arch-chroot "$MOUNT_DIR" pacman -S --needed --noconfirm -- "${desktop_pkgs[@]}"
  fi

  if [[ -n "$ROOTFS_EXTRA_PKGS" ]]; then
    read -r -a extra_pkgs <<< "$ROOTFS_EXTRA_PKGS"
    msg "安装额外包: ${extra_pkgs[*]}"
    sudo arch-chroot "$MOUNT_DIR" pacman -S --needed --noconfirm -- "${extra_pkgs[@]}"
  fi

  msg "配置系统"
  printf '%s\n' "$ROOTFS_HOSTNAME" | sudo tee "$MOUNT_DIR/etc/hostname" >/dev/null
  cat <<EOF | sudo tee "$MOUNT_DIR/etc/hosts" >/dev/null
127.0.0.1   localhost
127.0.1.1   $ROOTFS_HOSTNAME.localdomain $ROOTFS_HOSTNAME
::1         localhost ip6-localhost ip6-loopback
EOF

  # btrfs 需要显式挂载选项才能启用压缩；ext4 保持原样（不加 fstab）。
  if [[ "$ROOTFS_FS" == btrfs ]]; then
    local fstab_options="rw"
    [[ -z "$ROOTFS_BTRFS_OPTIONS" ]] || fstab_options="rw,$ROOTFS_BTRFS_OPTIONS"
    printf 'PARTLABEL=%s / btrfs %s 0 0\n' \
      "$ROOTFS_PARTLABEL" "$fstab_options" |
      sudo tee "$MOUNT_DIR/etc/fstab" >/dev/null
  fi

  sudo sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' "$MOUNT_DIR/etc/locale.gen"
  sudo arch-chroot "$MOUNT_DIR" locale-gen
  printf 'LANG=en_US.UTF-8\n' | sudo tee "$MOUNT_DIR/etc/locale.conf" >/dev/null

  printf 'root:%s\n' "$ROOTFS_PASSWORD" | sudo chpasswd -R "$MOUNT_DIR"
  if [[ -n "$ROOTFS_USER" ]]; then
    sudo arch-chroot "$MOUNT_DIR" useradd -m -G wheel -s /bin/bash "$ROOTFS_USER"
    printf '%s:%s\n' "$ROOTFS_USER" "$ROOTFS_PASSWORD" | sudo chpasswd -R "$MOUNT_DIR"
  fi

  sudo sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' \
    "$MOUNT_DIR/etc/sudoers"
  sudo arch-chroot "$MOUNT_DIR" systemctl enable NetworkManager

  case "$ROOTFS_DESKTOP" in
    gnome) sudo arch-chroot "$MOUNT_DIR" systemctl enable gdm ;;
    kde) sudo arch-chroot "$MOUNT_DIR" systemctl enable sddm ;;
    denial) sudo arch-chroot "$MOUNT_DIR" systemctl enable sddm ;;
  esac

  if denial_enabled; then
    configure_denial_session
  fi

  sudo install -d -m 0755 "$MOUNT_DIR/boot/loader/entries"
  cat <<EOF | sudo tee "$MOUNT_DIR/boot/loader/entries/arch.conf" >/dev/null
title Arch Linux (Xiaomi sheng)
linux /Image
initrd /initramfs-sheng.img
devicetree /sm8550-xiaomi-sheng.dtb
options $ROOTFS_KERNEL_CMDLINE
EOF

  msg "生成 initramfs 与 boot.img（post hook 仅构建镜像）"
  sudo arch-chroot "$MOUNT_DIR" mkinitcpio -p linux-xiaomi-sheng
  [[ -f "$MOUNT_DIR/boot/boot.img" ]] || die "boot.img 未生成"
  sudo cp "$MOUNT_DIR/boot/boot.img" "$boot_image"
  sudo chown "$(id -u):$(id -g)" "$boot_image"

  sudo arch-chroot "$MOUNT_DIR" pacman -Scc --noconfirm || true

  msg "卸载并检查文件系统"
  sudo umount -R "$MOUNT_DIR"
  verify_filesystem "$rootfs_image"

  msg "rootfs 已生成: $rootfs_image"
  msg "boot 镜像已生成: $boot_image"
  printf '刷写示例:\n'
  printf '  fastboot flash %s %s\n' "$ROOTFS_PARTLABEL" "$rootfs_image"
  printf '  fastboot flash boot_b %s\n' "$boot_image"
}

main
