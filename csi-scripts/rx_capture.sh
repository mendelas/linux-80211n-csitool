#!/bin/bash
# Intel 5300 CSI RX (ch48/5.240GHz/HT20)  使い方: ~/rx_capture.sh <ラベル>
CH=48
BW="HT20"
LABEL=${1:-csi}
IF=wlan1
sudo service network-manager stop 2>/dev/null
sudo modprobe -r iwlwifi mac80211 cfg80211 2>/dev/null
sudo modprobe iwlwifi connector_log=0x1
sleep 3
sudo iw reg set US
sleep 3
sudo ifconfig "$IF" down
sudo iwconfig "$IF" mode monitor
sudo ifconfig "$IF" up
sleep 3
sudo iw dev "$IF" set channel "$CH" "$BW"
echo "--- freq ---"; iwconfig "$IF" | grep -i freq
DIR="$HOME/csi_data/$(date +%Y%m%d)"
mkdir -p "$DIR"
OUT="$DIR/$(date +%Y%m%d_%H%M%S)_${LABEL}.csi"
echo "=== save: $OUT ==="
sudo ~/linux-80211n-csitool-supplementary/netlink/log_to_file "$OUT"
