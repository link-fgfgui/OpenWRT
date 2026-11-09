#!/bin/sh
# Verify the released squashfs artifact itself, without booting or flashing it.
set -eu

if [ "$#" -ne 2 ]; then
	echo "Usage: $0 OPENWRT_DIR SQUASHFS_IMAGE.img.gz" >&2
	exit 2
fi

OW_DIR=$1
IMAGE=$2
SFDISK="$OW_DIR/staging_dir/host/bin/sfdisk"
[ -x "$SFDISK" ] || SFDISK=$(command -v sfdisk || true)
UNSQUASHFS="$OW_DIR/staging_dir/host/bin/unsquashfs4"
[ -x "$UNSQUASHFS" ] || UNSQUASHFS=$(command -v unsquashfs || true)

[ -x "$SFDISK" ] || { echo 'Required image verification tool is missing: sfdisk' >&2; exit 1; }
[ -x "$UNSQUASHFS" ] || { echo 'Required image verification tool is missing: unsquashfs' >&2; exit 1; }
for tool in gzip dd awk od; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "Required image verification tool is missing: $tool" >&2
		exit 1
	}
done
[ -s "$IMAGE" ] || { echo "Image is missing or empty: $IMAGE" >&2; exit 1; }

image_bytes=$(wc -c < "$IMAGE")
[ "$image_bytes" -lt 268435456 ] || {
	echo "Compressed image is unexpectedly large: $image_bytes bytes" >&2
	exit 1
}

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM
gzip -dc "$IMAGE" > "$tmpdir/image.raw"
raw_bytes=$(wc -c < "$tmpdir/image.raw")
[ "$raw_bytes" -lt 268435456 ] || {
	echo "Raw image is unexpectedly large: $raw_bytes bytes" >&2
	exit 1
}

# The sunxi board image uses one FAT boot partition and one Linux root
# partition. Read its actual root partition start and length from the image.
geometry=$("$SFDISK" -d "$tmpdir/image.raw" | awk '
	/type=83/ {
		partition = $1
		sub(/:$/, "", partition)
		start = $0
		sub(/^.*start=[[:space:]]*/, "", start)
		sub(/,.*/, "", start)
		size = $0
		sub(/^.*size=[[:space:]]*/, "", size)
		sub(/,.*/, "", size)
		if (partition != "" && start ~ /^[0-9]+$/ && size ~ /^[0-9]+$/)
			print partition, start, size
	}')
set -- $geometry
[ "$#" -eq 3 ] || { echo 'Could not identify exactly one Linux root partition in the image' >&2; exit 1; }
root_partition=$1
root_start=$2
root_sectors=$3
# CONFIG_TARGET_ROOTFS_PARTSIZE=512 (512 MiB = 1048576 sectors) is the fixed
# factory partition; it is grown on first boot, not sized to the card.
[ "$root_sectors" -gt 0 ] && [ "$root_sectors" -le 1048576 ] || {
	echo "Root partition is not small: $root_sectors sectors" >&2
	exit 1
}
dd if="$tmpdir/image.raw" of="$tmpdir/root-partition.img" bs=512 skip="$root_start" count="$root_sectors" status=none

# Inspect files in the SquashFS embedded in the actual released partition.
"$UNSQUASHFS" -cat "$tmpdir/root-partition.img" lib/preinit/79_opi3lts_expand_storage > "$tmpdir/preinit-hook"
"$UNSQUASHFS" -cat "$tmpdir/root-partition.img" etc/init.d/opi3lts-expand-storage > "$tmpdir/expand-script"
grep -q 'boot_hook_add preinit_main opi3lts_expand_storage_preinit' "$tmpdir/preinit-hook" || {
	echo 'Released image lacks the preinit expansion hook' >&2
	exit 1
}
grep -q 'sfdisk --no-reread' "$tmpdir/expand-script" || {
	echo 'Released image lacks the partition expansion step' >&2
	exit 1
}
grep -q 'rebooting before mount_root' "$tmpdir/expand-script" || {
	echo 'Released image lacks the reboot-before-mount safety step' >&2
	exit 1
}
grep -q 'resize2fs' "$tmpdir/expand-script" || {
	echo 'Released image lacks the overlay filesystem expansion step' >&2
	exit 1
}
# /etc/rc.common enables procd for any non-empty USE_PROCD, including "0".  That
# replaces the script's own start() with a procd wrapper around start_service(),
# which this script does not define, so the whole expansion silently becomes a
# no-op.  Catch that regression here instead of on a flashed card.
if grep -qE '^[[:space:]]*USE_PROCD=' "$tmpdir/expand-script"; then
	echo 'Expansion script sets USE_PROCD; /etc/rc.common would replace start() with a no-op procd wrapper' >&2
	exit 1
fi
if grep -qE '/dev/mmcblk0|/home/ceaser' "$tmpdir/expand-script"; then
	echo 'Released image contains a hardcoded development device or host path' >&2
	exit 1
fi

printf 'Verified artifact: %s\n' "$IMAGE"
printf 'Compressed size: %s bytes; raw size: %s bytes\n' "$image_bytes" "$raw_bytes"
printf 'Root partition: %s, start %s sectors, size %s sectors\n' "$root_partition" "$root_start" "$root_sectors"
echo 'Embedded preinit and filesystem expansion scripts: OK'
