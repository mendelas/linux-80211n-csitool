#!/bin/bash
# Intel 5300 CSI injection TX (ch161/5.805GHz/HT20)  使い方: ~/tx_capture.sh
CH=161
BW="HT20"
RATE=0x4101
NPKTS=300000
PAYLOAD=100
DELAY=1000
IF=wlan1
sudo service network-manager stop 2>/dev/null
sudo iw dev mon0 del 2>/dev/null
sudo modprobe -r iwlwifi mac80211 cfg80211 2>/dev/null
sudo modprobe iwlwifi
sleep 3
sudo iw reg set US
sleep 3
sudo ifconfig "$IF" down
sudo iw dev "$IF" interface add mon0 type monitor
sudo iw dev "$IF" del
sudo ifconfig mon0 up
sleep 3
sudo iw dev mon0 set channel "$CH" "$BW"
echo "--- freq ---"; iwconfig mon0 | grep -i freq
RF=$(sudo find /sys/kernel/debug -name monitor_tx_rate | head -1)
echo "$RATE" | sudo tee "$RF" >/dev/null
echo "--- rate ---"; sudo cat "$RF"
echo "=== injecting ==="
cd ~/linux-80211n-csitool-supplementary/injection
sudo ./random_packets $NPKTS $PAYLOAD 1 $DELAY
