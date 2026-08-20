#!/bin/bash
# TX電力スイープ: 各電力で一定数パケットを注入し、25mW(14dBm)で足りるかを実測で判定する。
# 使い方: RX側で rx_capture.sh を先に起動 → TX側で ~/txpower_sweep.sh
# 判定: 得られた .csi を read_bf_file で読み、get_total_rss() をパケット順に並べると
#       電力ごとの段差が見える。14dBm の段で RSSI が -70dBm より上、かつパケットが
#       ちゃんと届いていれば 25mW で問題なし。
CH=48
BW="HT20"
RATE=0x4101          # HT40 にする場合は 0x4901
LEVELS="0 3 6 9 11 13 14 15 16"   # dBm。14dBm = 25mW
NPKTS=2000           # 各電力あたりの注入数
PAYLOAD=100
DELAY=1000           # us → 約1000pkt/s、1段あたり約2秒
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

# ★ txpower はチャネル設定より後でないと deferred される
sudo iw dev mon0 set channel "$CH" "$BW"
echo "--- freq ---"; iwconfig mon0 | grep -i freq

RF=$(sudo find /sys/kernel/debug -name monitor_tx_rate | head -1)
echo "$RATE" | sudo tee "$RF" >/dev/null
echo "--- rate ---"; sudo cat "$RF"

cd ~/linux-80211n-csitool-supplementary/injection || exit 1

for P in $LEVELS; do
    sudo dmesg -C 2>/dev/null
    sudo iw dev mon0 set txpower fixed "${P}00"
    # iw の戻り値は信用できない(ドライバの拒否が握り潰される)ので dmesg で確認する
    REJECT=$(dmesg | grep -i "TXPOWER" | tail -1)
    if [ -n "$REJECT" ]; then
        echo "=== ${P} dBm : ドライバが拒否 -> $REJECT  (スキップ)"
        continue
    fi
    echo "=== ${P} dBm ($(awk "BEGIN{printf \"%.1f\", 10^($P/10)}") mW) : ${NPKTS}パケット注入 ==="
    sudo ./random_packets "$NPKTS" "$PAYLOAD" 1 "$DELAY"
    sleep 2   # 段の切れ目を作る(RSSI系列で境界が見えるように)
done

echo "=== 完了。RX側を Ctrl+C で止めて解析してください ==="
