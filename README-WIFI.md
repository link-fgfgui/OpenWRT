# UWE5622 Wi-Fi 驱动适配说明

本文记录 Orange Pi 3 LTS 上 UNISOC UWE5622（板载 AW859A Wi-Fi/BT 组合模块）的 OpenWrt 适配方式、启动依赖和实机排错方法。当前项目验证的是 Wi-Fi AP；蓝牙不在本次适配范围内。

## 适配组成

| 部分 | 项目实现 |
| --- | --- |
| 内核 | ImmortalWrt v23.05.7（Linux 5.15） |
| 驱动 | `kmod-uwe5622`，使用 `armbian/uwe5622` commit `d6bec7538a0b4b67e35715ad71eaa056555524cb` |
| 模块 | `uwe5622_bsp_sdio.ko`（SDIO/WCN 总线）和 `sprdwl_ng.ko`（cfg80211 Wi-Fi） |
| 固件 | `uwe5622-firmware`，安装到 `/lib/firmware/uwe5622/` |
| 无线管理 | OpenWrt mac80211/cfg80211、hostapd、wifi-scripts |
| 板级硬件 | 本项目的 Orange Pi 3 LTS DTS：`sun50i-h6-orangepi-3-lts.dts` |

驱动包的 Makefile 位于 `overlay-23.05/package/kernel/uwe5622/`；补丁位于 `overlay/package/kernel/uwe5622/patches/`，固件文件及安装规则位于 `overlay/package/firmware/uwe5622-firmware/`。

## 设备树与 SDIO 上电

UWE5622 通过 H6 的 **MMC1 / SDIO** 总线连接。设备树补丁在 `overlay-23.05/target/linux/sunxi/patches-5.15/460-arm64-dts-allwinner-add-orangepi-3-lts.patch`，关键设置包括：

- `mmc1` 使用 4-bit、不可移除 SDIO 设备，并引用 `wifi_pwrseq`。
- `vcc33-wifi` 通过 PH7 控制 Wi-Fi 3.3 V 电源。
- 电源时序通过 `mmc-pwrseq-simple` 控制 PM3 低有效复位，并在上电后等待 200 ms。
- 电源时序需要 H6 RTC 提供 `CLK_OSC32K_FANOUT` 外部时钟。

因此 `scripts/apply-overlay.sh` 会在 sunxi Cortex-A53 内核配置中启用 `CONFIG_RTC_CLASS=y` 和 `CONFIG_RTC_DRV_SUN6I=y`。缺少 RTC 时钟提供者时，内核会报告 `wifi-pwrseq: external clock not ready`，设备留在 `devices_deferred`，MMC1 不会枚举 SDIO 卡；这时先修复设备树/内核时钟依赖，单独重编 Wi-Fi 模块无济于事。

不要用普通 Orange Pi 3 的 DTS 代替 LTS 设备树。LTS 板的 PMIC、GPIO、电源和无线连接需要按本项目的 `sun50i-h6-orangepi-3-lts.dts` 处理。

## 驱动补丁与内核 API

驱动来自树外的社区内核模块，需适配 ImmortalWrt 23.05 的 Linux 5.15 和 6.1 时代的 mac80211 backport。当前补丁主要处理：

- cfg80211 backport API 兼容，以及外部模块 Kbuild 配置符号传递。
- cfg80211/netdev 锁使用、连接和漫游状态同步。
- Linux 5.15 对 station/channel 查询、station dump 和可变长数组的变化。
- 驱动关闭省电时避免误执行芯片断电。

补丁按序号存放在 `overlay/package/kernel/uwe5622/patches/`。不要恢复旧的 `080-cfg80211-set-wiphy-params-backport-radio-idx.patch`：当前固定的 OpenWrt cfg80211 回调要求两参数函数；该旧补丁会强制三参数签名，导致 `incompatible-pointer-types` 编译失败。

构建必须先准备目标内核和 mac80211 backport，再编译 `package/kernel/uwe5622`。本项目脚本会按该顺序构建，并检查最终镜像清单及 UWE5622 驱动/固件包。

## 延迟加载与默认 AP

无线硬件晚于系统启动早期出现，因此驱动包不使用内核自动加载列表。`sprdwl-delay` 由 procd 在较晚阶段启动，等待后依次加载 `uwe5622_bsp_sdio`、`sprdwl_ng`，并等待 cfg80211 phy 出现。phy 就绪后再执行 `wifi config`，避免 OpenWrt 在无线设备尚不存在时漏掉 radio 配置。

首次发现 radio 时，`sprdwl-start` 创建并启用以下 AP；已有 UCI 无线配置会保留：

- 2.4 GHz，信道 6，HT20
- SSID `OrangePi-3-LTS`
- WPA2-PSK，初始密码 `orangepi@7`
- AP 接入 `lan`，LAN 地址 `192.168.8.1/24`

初始密码是公开值，用户应及时更改。启动脚本会把当前 Wi-Fi 密码写入 root 专用文件 `/root/opi3lts-wifi-password`，不会把密码写入系统日志。

选择 2.4 GHz HT20 是因为它已在该板上完成 AP、手机连接和上网验证。曾测试的 VHT80 配置在当前 hostapd 中因 `ieee80211ac` / `vht_*` 配置项不识别而失败；本项目不把 5 GHz VHT80 宣称为已验证功能。

> 23.05 使用 hostapd 2023-09-08 快照，5 GHz beacon 仍会带 DS Params IE，UWE5622 固件可以从中取到信道。

通过 UCI 修改 SSID、密码和信道：

```sh
uci set wireless.default_radio0.ssid='自己的名称'
uci set wireless.default_radio0.key='自己的至少八位密码'
uci set wireless.radio0.channel='11'
uci commit wireless
wifi reload
```

23.05 下切换到 5 GHz 的示例（只有一个 radio，会替换 2.4 GHz AP；149 为非 DFS 信道）：

```sh
uci set wireless.radio0.band='5g'
uci set wireless.radio0.channel='149'
uci set wireless.radio0.htmode='VHT80'
uci set wireless.radio0.country='CN'
uci commit wireless
wifi reload
```

如果 VHT80 不稳定，先退到 `HT20` 或 `HT40`。52–64 属于 DFS 信道，需要 hostapd 的 DFS/CAC 支持，建议先用 36–48 或 149–165。

## 实机验证

先检查 MMC/SDIO、电源时序、模块和 phy：

```sh
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
dmesg | grep -iE 'mmc1|wifi-pwrseq|uwe5622|sprd|sdio|firmware'
cat /sys/kernel/debug/devices_deferred
lsmod | grep -E 'uwe5622_bsp_sdio|sprdwl_ng'
iw dev
```

成功启动时应能看到 MMC1 识别 SDIO 卡、驱动读取 `/lib/firmware/uwe5622/` 下的固件/INI，并由 `iw dev` 列出无线 phy。AP 启动后检查：

```sh
wifi status
iw dev
logread | grep -iE 'hostapd|AP-ENABLED|AP-STA|handshake|dhcp'
iwinfo phy0-ap0 assoclist
cat /tmp/dhcp.leases
```

实机已验证的结果包括：`phy0-ap0` 类型为 AP、hostapd 报告 `AP-ENABLED`、WPA 四次握手完成、客户端从 LAN DHCP 获取地址并通过 `eth0` WAN 上网。应在重启后重复检查，以确认默认配置和延迟加载能恢复。

## 常见故障定位

| 现象 | 优先检查 |
| --- | --- |
| `wifi-pwrseq: external clock not ready`，没有 MMC1 | DTS 的 RTC 外部时钟引用；`RTC_CLASS`、`RTC_DRV_SUN6I` 是否进入实际内核配置；`devices_deferred` |
| MMC1 存在但扫描 SDIO 超时 | PH7 电源、PM3 复位、`mmc1` 的 `vmmc/vqmmc` 和 `wifi_pwrseq`；这是枚举/上电阶段，先不要查 hostapd |
| 模块已加载但没有 phy | MMC1 是否识别卡、`dmesg` 中 SDIO probe 和固件加载日志、驱动服务是否在设备出现后启动 |
| `iw dev` 有 phy，但无线配置为空 | 驱动加载后是否调用 `wifi config`；检查 `/etc/config/wireless` 和 `logread -e sprdwl-start` |
| hostapd 报 `unknown configuration item` 的 VHT/11ac 参数 | 先使用已验证的 2.4 GHz、信道 6、HT20 配置 |
| 手机关联成功但没有 IP | 检查 AP 是否加入 `lan`、`dhcp.lan.dhcpv4` 是否为 `server`、`br-lan` 地址是否为 `192.168.8.1/24` |

此记录反映当前固定源码和一块 Orange Pi 3 LTS 的实机结果；修改内核、驱动、无线包或 DTS 后，应重新编译并重新做整机验证。
