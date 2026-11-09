#!/bin/sh
# Build the Orange Pi 3 LTS image inside a Debian 12 podman container.
#
# The default build has no network access (--network=none).  Only "download"
# and "netbuild" use the network, and "netbuild" takes its proxy from the
# NETBUILD_PROXY environment variable.
#
#   sh scripts/build-podman.sh download   # network step, run it yourself
#   sh scripts/build-podman.sh clean      # drop host-specific build output
#   sh scripts/build-podman.sh build      # offline build, --network=none
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
IMAGE="${BUILDER_IMAGE:-localhost/opi3lts-builder:23.05}"
WORK_ROOT="${WORK_ROOT:-$HERE/.work}"
MOUNT_POINT="$WORK_ROOT/mnt"
OW_DIR="${OPENWRT_DIR:-$MOUNT_POINT/immortalwrt-23.05}"
JOBS="${JOBS:-$(nproc)}"
MODE="${1:-build}"
RUN_OFFLINE=0
RUN_DOWNLOAD_ONLY=0
RUN_PROXY=0

usage() {
	cat <<EOF
用法: $0 [build|download|clean|shell]

  build     离线构建镜像，容器使用 --network=none（默认）
  netbuild  联网构建：--network=host + 代理，缺失源码边编边下
            需要设置 NETBUILD_PROXY，例如 socks5h://127.0.0.1:7891
  download  在容器里执行 make download；这一步需要网络，由你执行
  clean     删除 $OW_DIR 下的 build_dir/staging_dir/tmp/bin
  shell     进入构建容器排查问题

首次准备（需要网络，由你执行）:
  podman pull docker.io/library/debian:12
  podman build -t ${IMAGE#localhost/} containers

构建目录是 $OW_DIR，需要先挂载 ext4 镜像:
  cd "$HERE" && fuse2fs .work/build.img .work/mnt
EOF
}

match_mode() {
	case "$MODE" in
		build|netbuild|download|clean|shell) ;;
		-h|--help|help) usage; exit 0 ;;
		*) usage >&2; exit 2 ;;
	esac
}
match_mode

need_image() {
	podman image exists "$IMAGE" && return 0
	cat >&2 <<EOF
错误：找不到构建镜像 $IMAGE。

先执行下面两条联网命令（由你操作）：

  podman pull docker.io/library/debian:12
  podman build -t ${IMAGE#localhost/} containers

EOF
	exit 2
}

need_mount() {
	case "$OW_DIR" in
		"$MOUNT_POINT"/*) ;;
		*) return 0 ;;
	esac
	mountpoint -q "$MOUNT_POINT" && return 0
	cat >&2 <<EOF
错误：$MOUNT_POINT 没有挂载。

先挂载构建用的 ext4 镜像（不联网）：

  cd "$HERE" && fuse2fs .work/build.img .work/mnt

EOF
	exit 2
}

# podman_run NETWORK COMMAND...
# The image has to come before COMMAND in "podman run"; RUN_OFFLINE and
# RUN_DOWNLOAD_ONLY select the in-container mode.
podman_run() {
	_net="$1"; shift
	_tty=""
	if [ -t 0 ] && [ -t 1 ]; then
		_tty="-it"
	fi
	_netarg=""
	if [ "$_net" = none ]; then
		_netarg="--network=none"
	elif [ "$_net" = host ]; then
		_netarg="--network=host"
	fi
	_proxyargs=""
	if [ "$RUN_PROXY" = 1 ]; then
		_proxyargs="-e ALL_PROXY -e http_proxy -e https_proxy -e CURL_OPTIONS"
	fi
	# shellcheck disable=SC2086
	podman run --rm $_tty $_netarg $_proxyargs \
		--security-opt label=disable \
		-v "$HERE/scripts:/repo/scripts:ro" \
		-v "$HERE/overlay:/repo/overlay:ro" \
		-v "$HERE/overlay-23.05:/repo/overlay-23.05:ro" \
		-v "$OW_DIR:/build" \
		-w /build \
		-e OPENWRT_DIR=/build \
		-e LOG_DIR=/build/_logs-23.05 \
		-e JOBS="$JOBS" \
		-e OFFLINE="$RUN_OFFLINE" \
		-e DOWNLOAD_ONLY="$RUN_DOWNLOAD_ONLY" \
		-e INCLUDE_DEV_TOOLS="${INCLUDE_DEV_TOOLS:-0}" \
		-e INCLUDE_ALL_KMODS="${INCLUDE_ALL_KMODS:-1}" \
		-e KERNEL_VERMAGIC_OVERRIDE="${KERNEL_VERMAGIC_OVERRIDE:-baeb12c0b157d65c5641792afff3f9af}" \
		"$IMAGE" "$@"
}

case "$MODE" in
	download)
		need_image
		need_mount
		echo '>> 这一步会在容器内联网下载 OpenWrt 源码和软件包'
		RUN_OFFLINE=0
		RUN_DOWNLOAD_ONLY=1
		podman_run default sh /repo/scripts/build-immortalwrt-23.05.sh
		;;

	clean)
		need_mount
		test -d "$OW_DIR/.git" || {
			echo "错误：$OW_DIR 不是源码目录" >&2
			exit 2
		}
		case "$OW_DIR" in
			"$MOUNT_POINT"/*|*/immortalwrt-23.05) ;;
			*) echo "错误：拒绝清理 $OW_DIR" >&2; exit 2 ;;
		esac
		echo ">> 删除 $OW_DIR 下的编译产物（保留 dl/ 和源码）"
		rm -rf "$OW_DIR/build_dir" "$OW_DIR/staging_dir" "$OW_DIR/tmp" "$OW_DIR/bin"
		;;

	netbuild)
		need_image
		need_mount
		if [ -z "${NETBUILD_PROXY:-}" ]; then
			cat >&2 <<EOF
错误：netbuild 需要 NETBUILD_PROXY。

  NETBUILD_PROXY=socks5h://127.0.0.1:7891 $0 netbuild

代理只通过环境变量传入容器，不写进仓库。
EOF
			exit 2
		fi
		rm -f "$OW_DIR/scripts/config/conf" "$OW_DIR"/scripts/config/*.o
		ALL_PROXY="$NETBUILD_PROXY"
		http_proxy=$ALL_PROXY
		https_proxy=$ALL_PROXY
		CURL_OPTIONS="--proxy $NETBUILD_PROXY"
		export ALL_PROXY http_proxy https_proxy CURL_OPTIONS
		RUN_PROXY=1
		RUN_OFFLINE=1
		RUN_DOWNLOAD_ONLY=0
		echo '>> 联网构建：--network=host，走 socks5 代理'
		podman_run host sh /repo/scripts/build-immortalwrt-23.05.sh
		;;

	build)
		need_image
		need_mount
		# scripts/config/conf lives in the source tree and a build on another
		# distro leaves a binary that the container's glibc cannot run.
		rm -f "$OW_DIR/scripts/config/conf" "$OW_DIR"/scripts/config/*.o
		echo '>> 离线构建：容器没有网络'
		RUN_OFFLINE=1
		RUN_DOWNLOAD_ONLY=0
		podman_run none sh /repo/scripts/build-immortalwrt-23.05.sh
		;;

	shell)
		need_image
		need_mount
		podman_run none bash
		;;
esac
