#!/bin/bash
# Intel 5300 CSI RX
#
# 使い方:  ~/rx_capture.sh <ラベル>
#   例) ~/rx_capture.sh walk01
#       CH=48 BW=HT20 ~/rx_capture.sh walk01_ch48
#
# ★ CH と BW は TX と完全一致させること。ズレると1パケットも受からない (エラーも出ない)
# 保存先: ~/csi_data/YYYYMMDD/YYYYMMDD_HHMMSS_<ラベル>.csi

CH=${CH:-161}                # TX と一致必須
BW=${BW:-HT40-}              # TX と一致必須
IF=${IF:-wlan1}
REG=${REG:-US}
LABEL=${1:-csi}

echo "=== RX: ch$CH $BW / label=$LABEL ==="

sudo service network-manager stop 2>/dev/null
sudo modprobe -r iwlwifi mac80211 cfg80211 2>/dev/null
sudo modprobe iwlwifi connector_log=0x1
sleep 3
sudo iw reg set "$REG"
sleep 3
sudo ifconfig "$IF" down
sudo iwconfig "$IF" mode monitor
sudo ifconfig "$IF" up
sleep 3

sudo iw dev "$IF" set channel "$CH" "$BW" || { echo "!! set channel 失敗"; exit 1; }

echo "--- 実際の設定 (要確認: width と center1 が TX と一致しているか) ---"
iw dev "$IF" info | grep -E 'channel|txpower'

DIR="$HOME/csi_data/$(date +%Y%m%d)"
mkdir -p "$DIR"
OUT="$DIR/$(date +%Y%m%d_%H%M%S)_${LABEL}.csi"
echo "=== save: $OUT  (Ctrl+C で停止) ==="
sudo ~/linux-80211n-csitool-supplementary/netlink/log_to_file "$OUT"
