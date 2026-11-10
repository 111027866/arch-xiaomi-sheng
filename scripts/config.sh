#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154
#
# arch-xiaomi-sheng —— 全局构建配置
# 所有脚本 source 此文件获取参数
#

# This file is sourced by scripts/lib/common.sh. PROJECT_DIR is derived from
# this repository's location, so commands work from any current directory.
: "${PROJECT_DIR:?scripts/config.sh must be sourced through scripts/lib/common.sh}"

# ── 构建环境 ──────────────────────────────────────────────
# clean chroot 路径（由 archbuild/makechrootpkg 使用）
BUILD_CHROOT="${BUILD_CHROOT:-/var/lib/archbuild}"

# ── 输出目录 ──────────────────────────────────────────────
OUT_DIR="${OUT_DIR:-$PROJECT_DIR/out}"
[[ "$OUT_DIR" == /* ]] || OUT_DIR="$PROJECT_DIR/$OUT_DIR"

# ── Rootfs 配置 ───────────────────────────────────────────
ROOTFS_DESKTOP="${ROOTFS_DESKTOP:-none}"       # none | kde | gnome
ROOTFS_EXTRA_PKGS="${ROOTFS_EXTRA_PKGS:-}"      # 额外 pacman 包（空格分隔）
ROOTFS_HOSTNAME="${ROOTFS_HOSTNAME:-sheng}"
ROOTFS_USER="${ROOTFS_USER:-alarm}"
ROOTFS_PASSWORD="${ROOTFS_PASSWORD:-alarm}"
ROOTFS_SIZE_MB="${ROOTFS_SIZE_MB:-4096}"         # rootfs.img 大小 (MiB)
ROOTFS_FS="${ROOTFS_FS:-ext4}"                   # ext4 | btrfs
ROOTFS_BTRFS_OPTIONS="${ROOTFS_BTRFS_OPTIONS:-compress=zstd:3,noatime}"
ROOTFS_PARTLABEL="${ROOTFS_PARTLABEL:-root}"      # 内核 root=PARTLABEL= 值
ROOTFS_KERNEL_CMDLINE="${ROOTFS_KERNEL_CMDLINE:-root=PARTLABEL=${ROOTFS_PARTLABEL} rw rootwait}"

# ── Denial 桌面（--desktop denial）────────────────────────
# Denial 只在官方 pacman 仓库发布 aarch64 二进制包。pacman 会自行展开
# Server 里的 $arch，因此默认值中的 $arch 必须保持字面量（用单引号覆盖时同理）。
ROOTFS_DENIAL_REPO="${ROOTFS_DENIAL_REPO:-https://packages.denialwm.org/arch/\$arch}"
ROOTFS_DENIAL_KEY_URL="${ROOTFS_DENIAL_KEY_URL:-https://packages.denialwm.org/denial-repo-key.asc}"
# 固定指纹：只有同时匹配该指纹的密钥才会被本地签名信任。
ROOTFS_DENIAL_KEY_FINGERPRINT="${ROOTFS_DENIAL_KEY_FINGERPRINT:-AE4108FA5E91E26BE0EE331E0F5B3AD16E023091}"
ROOTFS_DENIAL_PROFILE="${ROOTFS_DENIAL_PROFILE:-mobile}"   # mobile | desktop

# ── 派生路径（通常不需修改） ──────────────────────────────
PKG_DIR="$PROJECT_DIR/pkgs"
OUT_PKGS_DIR="$OUT_DIR/pkgs"
OUT_REPO_DIR="$OUT_DIR/repo"
OUT_ROOTFS_DIR="$OUT_DIR/rootfs"
