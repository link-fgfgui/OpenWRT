#!/bin/sh
# Build ImmortalWrt v23.05.7 for Orange Pi 3 LTS (Allwinner H6, Linux 5.15).
set -eu

OW_REPO="${OW_REPO:-https://github.com/immortalwrt/immortalwrt.git}"
OW_REF="${OW_REF:-v23.05.7}"
DEVICE="xunlong_orangepi-3-lts"
JOBS="${JOBS:-$(nproc)}"
INCLUDE_DEV_TOOLS="${INCLUDE_DEV_TOOLS:-0}"
INCLUDE_ALL_KMODS="${INCLUDE_ALL_KMODS:-1}"
# OFFLINE=1 reuses the existing checkout, feeds and dl/ cache and never calls
# git/feeds update or make download.  DOWNLOAD_ONLY=1 stops right after the
# network-dependent `make download` step so it can be run separately.
OFFLINE="${OFFLINE:-0}"
DOWNLOAD_ONLY="${DOWNLOAD_ONLY:-0}"
# STAGE splits the build for CI: base builds host tools, the cross toolchain
# and the kernel; packages compiles the package set; image installs packages
# and produces the SD-card images.  The default runs every stage in one go.
STAGE="${STAGE:-all}"
# PACKAGE_TIMEOUT (seconds) stops package/compile before a CI job timeout so
# the build tree can still be cached.  A timeout is not treated as an error.
PACKAGE_TIMEOUT="${PACKAGE_TIMEOUT:-0}"
case "$STAGE" in
	all|base|packages|image) ;;
	*) echo "Unknown STAGE: $STAGE" >&2; exit 2 ;;
esac
# Official ImmortalWrt v23.05.7 sunxi/cortexa53 kernel vermagic.  We still
# build three board-specific symbols (RTC_CLASS, RTC_DRV_SUN6I and
# MOTORCOMM_PHY) that the official config disables, so the real config hash
# differs.  Rewriting .vermagic after the kernel build makes the "kernel"
# package version and the distfeeds kmods URL match the official repository.
KERNEL_VERMAGIC_OVERRIDE="${KERNEL_VERMAGIC_OVERRIDE:-baeb12c0b157d65c5641792afff3f9af}"
if [ "$OW_REF" != "v23.05.7" ] && [ "$KERNEL_VERMAGIC_OVERRIDE" = "baeb12c0b157d65c5641792afff3f9af" ]; then
	echo "WARNING: the default KERNEL_VERMAGIC_OVERRIDE is for ImmortalWrt v23.05.7; update it for $OW_REF" >&2
fi
HERE="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OW_DIR="${OPENWRT_DIR:-$HERE/.work/immortalwrt-23.05}"
LOG_DIR="${LOG_DIR:-$HERE/_logs-23.05}"

mkdir -p "$(dirname "$OW_DIR")" "$LOG_DIR"
mkdir -p "$OW_DIR/.fs-probe"
if ! ( : > "$OW_DIR/.fs-probe/aux.c" ) 2>/dev/null; then
	rm -rf "$OW_DIR/.fs-probe"
	echo "ERROR: $OW_DIR cannot store the Linux kernel tree (file name 'aux.c' rejected)." >&2
	echo "Set OPENWRT_DIR to an ext4 path; NTFS/exFAT mounts cannot hold some kernel source files." >&2
	exit 1
fi
rm -rf "$OW_DIR/.fs-probe"
export FORCE_UNSAFE_CONFIGURE=1

run_logged() {
	_run_log_file="$1"
	shift
	_run_status_file="${_run_log_file}.status"
	rm -f "$_run_status_file"
	(
		set +e
		"$@"
		_run_exit_status=$?
		printf '%s\n' "$_run_exit_status" > "$_run_status_file"
		exit "$_run_exit_status"
	) 2>&1 | tee "$_run_log_file"
	if [ ! -f "$_run_status_file" ]; then
		return 1
	fi
	_run_logged_status=$(cat "$_run_status_file")
	rm -f "$_run_status_file"
	return "$_run_logged_status"
}

prepare_fakeroot() {
	_fakeroot_bin="$OW_DIR/staging_dir/host/bin/fakeroot"
	if [ ! -x "$_fakeroot_bin" ] || "$_fakeroot_bin" true >/dev/null 2>&1; then
		return 0
	fi
	if [ -x /usr/bin/fakeroot ]; then
		if [ ! -e "$_fakeroot_bin.openwrt" ]; then
			cp -p "$_fakeroot_bin" "$_fakeroot_bin.openwrt"
		fi
		cat > "$_fakeroot_bin" <<'FAKEROOT'
#!/bin/sh
exec /usr/bin/fakeroot "$@"
FAKEROOT
		chmod 0755 "$_fakeroot_bin"
		echo "Using /usr/bin/fakeroot because the OpenWrt host fakeroot cannot create its daemon socket"
		return 0
	fi
	echo "OpenWrt fakeroot cannot create its daemon socket and /usr/bin/fakeroot is unavailable" >&2
	return 1
}

if [ ! -d "$OW_DIR/.git" ]; then
	if [ "$OFFLINE" = 1 ]; then
		echo "ERROR: $OW_DIR has no Git checkout and OFFLINE=1 forbids cloning it." >&2
		exit 1
	fi
	echo ">> Cloning $OW_REPO at $OW_REF"
	if [ -e "$OW_DIR" ] && [ -n "$(find "$OW_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
		echo "Refusing to replace non-empty directory without a Git checkout: $OW_DIR" >&2
		exit 1
	fi
	git clone --depth 1 --branch "$OW_REF" "$OW_REPO" "$OW_DIR"
elif [ "$OFFLINE" = 1 ]; then
	echo '>> Offline: keeping the existing source checkout'
else
	wanted=$(git -C "$OW_DIR" rev-parse --verify --quiet "$OW_REF^{commit}" || true)
	if [ -z "$wanted" ]; then
		git -C "$OW_DIR" fetch --depth 1 origin "$OW_REF" 2>/dev/null \
			|| git -C "$OW_DIR" fetch --depth 1 origin "refs/tags/$OW_REF"
		wanted=$(git -C "$OW_DIR" rev-parse --verify --quiet 'FETCH_HEAD^{commit}')
	fi
	current=$(git -C "$OW_DIR" rev-parse HEAD)
	if [ "$current" != "$wanted" ]; then
		git -C "$OW_DIR" checkout --detach "$wanted"
	fi
fi
echo "Source: $OW_REPO @ $(git -C "$OW_DIR" rev-parse HEAD) ($OW_REF)"

cd "$OW_DIR"

# CONFIG_ALL_KMODS must see routing/telephony kmods as well; the official
# all-kmods kernel config includes them.
if [ "$OFFLINE" = 1 ]; then
	echo '>> Offline: skipping feeds update'
else
	echo ">> Update and install all feeds"
	run_logged "$LOG_DIR/feeds-update.log" ./scripts/feeds update -a
fi
echo ">> Install feeds from the local feed checkouts"
run_logged "$LOG_DIR/feeds-install.log" ./scripts/feeds install -a

echo ">> Applying project overlay (5.15)"
sh "$HERE/scripts/apply-overlay.sh" "$OW_DIR"

cat > .config <<CONFIG
CONFIG_TARGET_sunxi=y
CONFIG_TARGET_sunxi_cortexa53=y
CONFIG_TARGET_sunxi_cortexa53_DEVICE_${DEVICE}=y
CONFIG_TARGET_ROOTFS_PARTSIZE=512
CONFIG_DEVEL=y
CONFIG_PER_FEED_REPO=y
CONFIG_FEED_packages=y
CONFIG_FEED_luci=y
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_uhttpd=y
CONFIG_PACKAGE_uhttpd-mod-ubus=y
CONFIG_PACKAGE_luci-mod-admin-full=y
CONFIG_PACKAGE_luci-compat=y
# CONFIG_PACKAGE_dnsmasq is not set
CONFIG_PACKAGE_dnsmasq-full=y
CONFIG_PACKAGE_libnettle=y
CONFIG_PACKAGE_libnetfilter-conntrack=y
CONFIG_PACKAGE_sfdisk=y
CONFIG_PACKAGE_partx-utils=y
CONFIG_PACKAGE_losetup=y
CONFIG_PACKAGE_resize2fs=y
CONFIG_DRIVER_11AC_SUPPORT=y
CONFIG_PACKAGE_luci-i18n-base-zh-cn=y
CONFIG_PACKAGE_luci-i18n-firewall-zh-cn=y
CONFIG
if [ "$INCLUDE_ALL_KMODS" = 1 ]; then
	# Align the kernel module set with the official all-kmods build.
	echo 'CONFIG_ALL_KMODS=y' >> .config
	# Match the official buildbot kernel configuration (config.buildinfo).
	# The official kmods are built with tracing/BPF/perf/kprobes enabled and
	# reference symbols such as kmem_cache_alloc_trace and trace_*; without
	# these options our kernel does not export them and the official modules
	# fail to load with "Unknown symbol".
	cat >> .config <<CONFIG
CONFIG_KERNEL_ARM_PMU=y
CONFIG_KERNEL_BPF_EVENTS=y
CONFIG_KERNEL_BPF_STREAM_PARSER=y
CONFIG_KERNEL_FTRACE=y
CONFIG_KERNEL_KPROBES=y
CONFIG_KERNEL_KPROBE_EVENTS=y
CONFIG_KERNEL_PERF_EVENTS=y
CONFIG_KERNEL_XDP_SOCKETS=y
CONFIG
fi
if [ "$INCLUDE_DEV_TOOLS" = 1 ]; then
	cat >> .config <<CONFIG
CONFIG_PACKAGE_git=y
CONFIG_PACKAGE_git-http=y
CONFIG_PACKAGE_make=y
CONFIG_PACKAGE_gcc=y
CONFIG_PACKAGE_binutils=y
CONFIG
fi

echo ">> Configure"
run_logged "$LOG_DIR/defconfig.log" make defconfig
cp .config "$LOG_DIR/immortalwrt-23.05.config"
grep -qx 'CONFIG_TARGET_sunxi_cortexa53_DEVICE_'"$DEVICE"'=y' .config || {
	echo 'Orange Pi 3 LTS device was not selected' >&2
	exit 1
}
grep -qx 'CONFIG_TARGET_ROOTFS_PARTSIZE=512' .config || {
	echo 'Unexpected rootfs partition size' >&2
	exit 1
}
grep -qx 'CONFIG_DRIVER_11AC_SUPPORT=y' .config || {
	echo 'hostapd 802.11ac support is not enabled' >&2
	exit 1
}
if [ "$INCLUDE_ALL_KMODS" = 1 ]; then
	grep -qx 'CONFIG_ALL_KMODS=y' .config || {
		echo 'CONFIG_ALL_KMODS was not selected' >&2
		exit 1
	}
	for opt in \
		CONFIG_KERNEL_ARM_PMU \
		CONFIG_KERNEL_BPF_EVENTS \
		CONFIG_KERNEL_BPF_STREAM_PARSER \
		CONFIG_KERNEL_FTRACE \
		CONFIG_KERNEL_KPROBES \
		CONFIG_KERNEL_KPROBE_EVENTS \
		CONFIG_KERNEL_PERF_EVENTS \
		CONFIG_KERNEL_XDP_SOCKETS; do
		grep -qx "$opt=y" .config || {
			echo "Official kmod compatibility option was dropped: $opt" >&2
			exit 1
		}
	done
fi

if [ "$DOWNLOAD_ONLY" = 1 ]; then
	echo ">> Download sources (network)"
	run_logged "$LOG_DIR/download.log" make -j"$JOBS" download
	echo "Source download completed: $OW_DIR/dl"
	exit 0
fi

if [ "$STAGE" = base ] || [ "$STAGE" = all ]; then
	if [ "$OFFLINE" = 1 ]; then
		echo '>> Offline: skipping source download'
	else
		echo ">> Download sources"
		run_logged "$LOG_DIR/download.log" make -j"$JOBS" download
	fi

	echo ">> Build host tools and cross toolchain"
	run_logged "$LOG_DIR/toolchain-install.log" make -j"$JOBS" toolchain/install

	echo ">> Build target kernel and modules"
	run_logged "$LOG_DIR/target-linux-compile.log" make -j"$JOBS" target/linux/compile
	if [ -n "$KERNEL_VERMAGIC_OVERRIDE" ]; then
		VERMAGIC_FILE=$(find "$OW_DIR/build_dir" -path '*/linux-sunxi_cortexa53/linux-*/.vermagic' -print -quit)
		test -n "$VERMAGIC_FILE" || {
			echo 'Kernel .vermagic file was not generated' >&2
			exit 1
		}
		echo "$KERNEL_VERMAGIC_OVERRIDE" > "$VERMAGIC_FILE"
		rm -f "$OW_DIR/tmp/.packageinfo" "$OW_DIR/tmp/.packagedeps"
		echo ">> Kernel vermagic overridden for official kmods: $KERNEL_VERMAGIC_OVERRIDE"
	fi

	if [ "$STAGE" = base ]; then
		echo "Base stage completed: $OW_DIR"
		exit 0
	fi
fi

prepare_fakeroot

if [ "$STAGE" = packages ] && [ "$PACKAGE_TIMEOUT" != 0 ]; then
	echo ">> Build packages (timeout ${PACKAGE_TIMEOUT}s)"
	set +e
	run_logged "$LOG_DIR/package-compile.log" \
		timeout -k 60 "$PACKAGE_TIMEOUT" make -j"$JOBS" package/compile
	_package_status=$?
	set -e
	if [ "$_package_status" -ne 0 ] && [ "$_package_status" -ne 124 ]; then
		exit "$_package_status"
	fi
	if [ "$_package_status" -eq 124 ]; then
		echo "Package stage paused before completion: $OW_DIR"
	fi
	exit 0
fi

echo ">> Build packages"
run_logged "$LOG_DIR/package-compile.log" make -j"$JOBS" package/compile
if [ "$STAGE" = packages ]; then
	echo "Package stage completed: $OW_DIR"
	exit 0
fi

echo ">> Install packages into the image root"
run_logged "$LOG_DIR/package-install.log" make -j"$JOBS" package/install
if [ -n "$KERNEL_VERMAGIC_OVERRIDE" ]; then
	ROOTFS_DIR=$(find "$OW_DIR/build_dir" -type d -path '*/root-sunxi' -print -quit)
	DISTFEEDS="$ROOTFS_DIR/etc/opkg/distfeeds.conf"
	if [ -f "$DISTFEEDS" ]; then
		sed -i -E "s|/kmods/[0-9][^/]*/|/kmods/5.15.195-1-$KERNEL_VERMAGIC_OVERRIDE/|" "$DISTFEEDS"
		# ImmortalWrt 23.05 emits no kmods feed.  Add one pointing at the
		# official all-kmods URL for the overridden vermagic, deriving the
		# release/target prefix from the core feed so no URL is hardcoded.
		if ! grep -q '_kmods ' "$DISTFEEDS"; then
			FEED_BASE=$(sed -n 's|^src/gz [^ ]* \(.*\)/packages$|\1|p' "$DISTFEEDS" | head -n1)
			if [ -n "$FEED_BASE" ]; then
				printf 'src/gz immortalwrt_kmods %s/kmods/5.15.195-1-%s\n' \
					"$FEED_BASE" "$KERNEL_VERMAGIC_OVERRIDE" >> "$DISTFEEDS"
			fi
		fi
	fi
fi

echo ">> Build target image"
run_logged "$LOG_DIR/target-install.log" make -j1 V=s target/install

STORAGE_INIT=$(find "$OW_DIR/build_dir" -type f -path '*/root-sunxi/etc/init.d/opi3lts-expand-storage' -print -quit)
test -n "$STORAGE_INIT" || { echo 'SD-card expansion init script is missing from the image root' >&2; exit 1; }
STORAGE_ROOT=${STORAGE_INIT%/etc/init.d/opi3lts-expand-storage}
test -f "$STORAGE_ROOT/lib/preinit/79_opi3lts_expand_storage" || {
	echo 'SD-card expansion preinit hook is missing from the image root' >&2
	exit 1
}
test -L "$STORAGE_ROOT/etc/rc.d/S99opi3lts-expand-storage" || {
	echo 'SD-card expansion init script is not enabled at S99' >&2
	exit 1
}
if [ -n "$KERNEL_VERMAGIC_OVERRIDE" ]; then
	DISTFEEDS="$STORAGE_ROOT/etc/opkg/distfeeds.conf"
	if [ -f "$DISTFEEDS" ] && ! grep -q "kmods/.*-$KERNEL_VERMAGIC_OVERRIDE" "$DISTFEEDS"; then
		echo "WARNING: distfeeds.conf does not point at the overridden kmods hash" >&2
	fi
fi

echo ">> Generate package indexes and checksums"
run_logged "$LOG_DIR/package-index.log" make -j"$JOBS" package/index json_overview_image_info checksum

echo ">> Verify expected image and driver packages exist"
IMAGE_DIR="bin/targets/sunxi/cortexa53"
test -d "$IMAGE_DIR"
DIST=$(sed -n 's/^CONFIG_VERSION_DIST="\(.*\)"$/\1/p' .config | head -n1)
[ -n "$DIST" ] || DIST=ImmortalWrt
DIST_LC=$(printf '%s' "$DIST" | tr 'A-Z' 'a-z')
MANIFEST="$IMAGE_DIR/${DIST_LC}-sunxi-cortexa53-${DEVICE}.manifest"
test -s "$MANIFEST" || { echo "Image manifest is missing: $MANIFEST" >&2; exit 1; }
for package in \
	luci-base luci-mod-admin-full uhttpd uhttpd-mod-ubus \
	dnsmasq-full libnettle8 libnetfilter-conntrack3 \
	sfdisk partx-utils losetup resize2fs \
	luci-i18n-base-zh-cn luci-i18n-firewall-zh-cn; do
	grep -q "^${package} " "$MANIFEST" || { echo "Expected package is missing: $package" >&2; exit 1; }
done
find "$IMAGE_DIR" -maxdepth 1 -type f -name '*xunlong_orangepi-3-lts*' -print > "$LOG_DIR/images.txt"
cat "$LOG_DIR/images.txt"
grep -q '\.img\.gz$' "$LOG_DIR/images.txt" || { echo 'Orange Pi 3 LTS .img.gz image was not generated' >&2; exit 1; }
SQUASHFS_IMAGE="$IMAGE_DIR/${DIST_LC}-sunxi-cortexa53-${DEVICE}-squashfs-sdcard.img.gz"
test -s "$SQUASHFS_IMAGE" || { echo "SquashFS image is missing: $SQUASHFS_IMAGE" >&2; exit 1; }
sh "$HERE/scripts/verify-image.sh" "$OW_DIR" "$OW_DIR/$SQUASHFS_IMAGE"
: > "$LOG_DIR/uwe5622-packages.txt"
for package_dir in "$IMAGE_DIR/packages" bin/packages; do
	if [ -d "$package_dir" ]; then
		find "$package_dir" -type f \( -name 'kmod-uwe5622*.ipk' -o -name 'uwe5622-firmware*.ipk' \) -print >> "$LOG_DIR/uwe5622-packages.txt"
	fi
done
cat "$LOG_DIR/uwe5622-packages.txt"
grep -q 'kmod-uwe5622' "$LOG_DIR/uwe5622-packages.txt" || { echo 'kmod-uwe5622 package was not generated' >&2; exit 1; }
grep -q 'uwe5622-firmware' "$LOG_DIR/uwe5622-packages.txt" || { echo 'uwe5622-firmware package was not generated' >&2; exit 1; }

echo "Build completed: $OW_DIR/$IMAGE_DIR"
