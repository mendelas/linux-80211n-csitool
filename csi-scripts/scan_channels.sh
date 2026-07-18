#!/bin/bash
# 5GHz 空きチャネル調査 — injection 前に CLEAR な ch を探す。
# 使い方: ~/scan_channels.sh [IF]        (既定 wlan1)
#   Part A: managed mode で 5GHz 全 AP をスキャン → ch ごとの AP 数/最強信号
#   Part B: monitor mode で injection 候補 ch を実測 → 3 秒間のフレーム数
# AP が居ない & フレーム数が少ない ch = 空き。そこに CH= を合わせる。
IF=${1:-wlan1}
CANDIDATES="36 44 48 149 153 157 161 165"   # 非DFS (W52 + UNII-3)。injection 可能な帯のみ

# --- ドライバをクリーンに再ロード（managed mode）---
sudo service network-manager stop 2>/dev/null
sudo modprobe -r iwlwifi mac80211 cfg80211 2>/dev/null
sudo modprobe iwlwifi
sleep 3
sudo iw reg set US            # UNII-3 (ch149-165) を見えるようにする
sleep 1
sudo ip link set "$IF" up
sleep 1

echo "==================================================================="
echo " Part A: 5GHz AP scan (managed mode)  IF=$IF"
echo "==================================================================="
SCAN=$(sudo iw dev "$IF" scan 2>/dev/null)
[ -z "$SCAN" ] && { sleep 2; SCAN=$(sudo iw dev "$IF" scan 2>/dev/null); }

echo "$SCAN" | awk '
  /freq:/    { freq=$2 }
  /signal:/  { sig=$2+0; if (freq>=5000) { cnt[freq]++; if (best[freq]=="" || sig>best[freq]) best[freq]=sig } }
  /SSID:/    { s=$0; sub(/^[ \t]*SSID: /,"",s); if (freq>=5000 && s!="") ssid[freq]=ssid[freq] s " " }
  END {
    printf "%-6s %-8s %-6s %-8s  %s\n","ch","freq","#AP","strongest","SSIDs"
    printf "%-6s %-8s %-6s %-8s  %s\n","----","----","---","--------","-----"
    n=0
    for (f in cnt) { fr[n]=f; n++ }
    # sort by AP count desc (busiest first)
    for (i=0;i<n;i++) for (j=i+1;j<n;j++) if (cnt[fr[j]]>cnt[fr[i]]) { t=fr[i];fr[i]=fr[j];fr[j]=t }
    for (i=0;i<n;i++){ f=fr[i]; ch=(f-5000)/5; printf "ch%-4d %-8d %-6d %-8s  %s\n", ch, f, cnt[f], best[f]" dBm", ssid[f] }
    if (n==0) print "(5GHz に AP は見つからず — 全 ch 空き、または scan 未対応)"
  }'

echo
echo "==================================================================="
echo " Part B: injection 候補 ch の実測 (monitor mode, 各 3 秒)"
echo "  → フレーム数が少ないほど空き。0〜数十程度なら十分クリア。"
echo "==================================================================="
sudo ip link set "$IF" down
sudo iw dev "$IF" set type monitor 2>/dev/null
sudo ip link set "$IF" up
printf "%-6s %-8s %s\n" "ch" "MHz" "frames/3s"
printf "%-6s %-8s %s\n" "----" "----" "---------"
for CH in $CANDIDATES; do
  MHZ=$((5000 + CH*5))
  if sudo iw dev "$IF" set channel "$CH" 2>/dev/null; then
    N=$(sudo timeout 3 tcpdump -i "$IF" -c 1000 2>/dev/null | grep -c .)
    FLAG=""; [ "$N" -le 30 ] && FLAG="  <= 空き候補"
    printf "ch%-4d %-8d %d%s\n" "$CH" "$MHZ" "$N" "$FLAG"
  else
    printf "ch%-4d %-8d (設定不可: DFS/reg 制約)\n" "$CH" "$MHZ"
  fi
done

echo
echo "空き ch を決めたら rx/tx スクリプトの CH= に設定。TX と全 RX で一致必須。"
echo "（W52: ch36/44/48 は免許不要。UNII-3: ch149-165 は 5.8GHz 実験試験局が必要）"
