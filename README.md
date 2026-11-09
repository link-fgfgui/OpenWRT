# Orange Pi 3 LTS · OpenWrt AP 路由器

为全志 H6 的 Orange Pi 3 LTS 构建 OpenWrt 固件，包含板级 DTS、UWE5622 Wi-Fi 驱动、默认 AP 和 LuCI 网页管理。构建 **ImmortalWrt v23.05.7（Linux 5.15）**。

Wi-Fi 已在 Orange Pi 3 LTS 实机上验证：手机可连接 AP、获取地址并通过有线 WAN 上网。驱动适配细节和排错步骤见 [Wi-Fi 驱动适配说明](README-WIFI.md)。

23.05 默认 `CONFIG_ALL_KMODS=y`，并把内核 `.vermagic` 覆写为官方 v23.05.7 sunxi/cortexa53 的 `baeb12c0b157d65c5641792afff3f9af`，这样设备上的官方 kmods 源可以直接 `opkg install kmod-*`。内核实际仍内建 `RTC_CLASS`、`RTC_DRV_SUN6I` 和 `MOTORCOMM_PHY`，与官方 config 不完全相同；可用 `INCLUDE_ALL_KMODS=0` 或 `KERNEL_VERMAGIC_OVERRIDE=` 关闭。

## 默认网络

| 项目 | 默认值 |
| --- | --- |
| WAN | `eth0`，DHCP 客户端 |
| 路由器地址 | `192.168.8.1/24` |
| LAN DHCP 地址池 | `192.168.8.100` 起 |
| Wi-Fi | 2.4 GHz，信道 6，HT20，WPA2-PSK |
| SSID / 密码 | `OrangePi-3-LTS` / `orangepi@7` |
| LuCI | `http://192.168.8.1`，简体中文 |

Wi-Fi 密码是公开的初始值，部署后请立即修改。设备不预设 root 管理密码；首次启动通过 SSH 免密连接运行 `passwd` 设置密码，再登录 LuCI。

## 构建

推荐 Debian 12 或 Ubuntu 22.04 x86-64，至少 4 核、8 GB 内存和 25 GB 可用磁盘；也可以直接用仓库里的 podman 环境。首次构建耗时较长；保留构建目录，之后会复用未变化的工具链、内核和软件包。

```sh
# 源码放在 .work/immortalwrt-23.05
sh scripts/build.sh

# 复用已有的源码目录
OPENWRT_DIR="$PWD/ow" JOBS="$(nproc)" sh scripts/build.sh
```

目标端开发工具（git、make、gcc、binutils）用 `INCLUDE_DEV_TOOLS=1` 加入。

### podman

```sh
podman pull docker.io/library/debian:12
podman build -t localhost/opi3lts-builder:23.05 containers
OPENWRT_DIR=/path/to/immortalwrt-23.05 sh scripts/build-podman.sh build
```

产物在 `bin/targets/sunxi/cortexa53/`，包含 ext4 与 squashfs SD 卡镜像、manifest、`sha256sums` 和 Wi-Fi 驱动 ipk。

## 刷写

解压 `.img.gz`，确认 `/dev/sdX` 是 SD 卡设备后写入（也可以用 balenaEtcher 直接刷入）：

```sh
gunzip -k immortalwrt-sunxi-cortexa53-xunlong_orangepi-3-lts-squashfs-sdcard.img.gz
sudo dd if=immortalwrt-sunxi-cortexa53-xunlong_orangepi-3-lts-squashfs-sdcard.img \
  of=/dev/sdX bs=4M status=progress conv=fsync
```

**写错设备会清除该设备上的数据。** 镜像使用本仓库的 SPL/U-Boot 和 Orange Pi 3 LTS 专用设备树。

首次启动会运行 `opi3lts-expand-storage`：preinit 阶段先扩分区，挂载 overlay 后扩展文件系统，把根分区占满整张卡；必要时会自动重启一次让内核读到新分区表。写入不同容量的卡后，可用下面的命令确认：

```sh
logread -e opi3lts-expand-storage
cat /proc/partitions
df -h
ls -l /etc/opi3lts-storage-expanded
```

## 修改 Wi-Fi

可在 LuCI 的 **Network → Wireless** 修改，也可通过 SSH/串口使用 UCI：

```sh
uci set wireless.default_radio0.ssid='SSID'
uci set wireless.default_radio0.key='password'
uci commit wireless
wifi reload
```

初次启动时驱动服务创建默认无线配置；之后会保留已有设置，建议重启后再投入使用。
