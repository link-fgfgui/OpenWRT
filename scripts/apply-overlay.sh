#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
	echo "Usage: $0 OPENWRT_SOURCE_DIR" >&2
	exit 2
fi

HERE="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OW_DIR="$1"
CORTEXA53_KERNEL_CONFIG="$OW_DIR/target/linux/sunxi/cortexa53/config-5.15"
mkdir -p "$(dirname "$CORTEXA53_KERNEL_CONFIG")"

copy_overlay() {
	_overlay="$1"
	[ -d "$_overlay" ] || return 0
	find "$_overlay" -type f -print | while IFS= read -r source_file; do
		relative_path=${source_file#"$_overlay"/}
		target_file="$OW_DIR/$relative_path"
		if [ -f "$target_file" ] && cmp -s "$source_file" "$target_file"; then
			continue
		fi
		mkdir -p "$(dirname "$target_file")"
		cp -p "$source_file" "$target_file"
		touch "$target_file"
	done
}

copy_overlay "$HERE/overlay"
copy_overlay "$HERE/overlay-23.05"

# Drop this obsolete project patch from an existing local build tree. It forces
# a three-argument callback although the pinned cfg80211 backport expects the
# two-argument set_wiphy_params callback.
rm -f "$OW_DIR/package/kernel/uwe5622/patches/080-cfg80211-set-wiphy-params-backport-radio-idx.patch"

# The H6 RTC driver also registers the OSC32K_FANOUT clock provider used by
# the Orange Pi 3 LTS Wi-Fi MMC power sequence. Without RTC_CLASS the provider
# is omitted, leaving wifi-pwrseq deferred and preventing mmc1 from probing.
append_kernel_symbol() {
	_symbol="$1"
	_config="$2"
	if ! grep -Fqx "CONFIG_${_symbol}=y" "$_config"; then
		sed -i "/^CONFIG_${_symbol}=/d; /^# CONFIG_${_symbol} is not set$/d" "$_config"
		printf 'CONFIG_%s=y\n' "$_symbol" >> "$_config"
	fi
}

# The LTS board uses a Motorcomm YT8531C RGMII PHY. 23.05 ships the v6.3
# backport that adds YT8531 support, but the symbol is not enabled in the
# sunxi cortexa53 config fragment.
for symbol in RTC_CLASS RTC_DRV_SUN6I MOTORCOMM_PHY; do
	append_kernel_symbol "$symbol" "$CORTEXA53_KERNEL_CONFIG"
done
