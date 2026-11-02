#!/bin/bash
# Intel 5300 TX 切り分け (実験機のラップトップ上で実行。ネット不要)
#
# 使い方:  ~/tx_diag.sh            電波を出さずに TX の前提条件を点検
#          ~/tx_diag.sh --send     上に加えて 3000 発 (約3秒) 送信し、どの層で消えるか判定
#          ~/tx_diag.sh --rx [秒]  受信機側で待ち受け、注入フレーム / HT / CSI を数える (既定 20 秒)
#   例) CH=48 BW=HT40- REG=JP ~/tx_diag.sh --send    (W52。送受で同じ値に)
#       RATE=0x8901 ~/tx_diag.sh --send              (アンテナ B で送信。C は 0x10901)
#
# ★ --send は実際に電波を出す。既定の ch157 HT40+ は免許またはシールド環境が前提
#    (SETUP_CSITOOL_JA.md §4-C)。それ以外の場所では上の CH=48 の形で実行すること。
#
# random_packets / tx_inject の "sent" は write() の成否でしかない。mac80211 が黙って捨てても
# 成功に見えるので、ここでは mac80211 の statistics カウンタで判定する (ACK が返らない注入
# フレームでも、ファームが完了報告すれば failed_count が増える)。

CH=${CH:-157}
BW=${BW:-HT40+}
REG=${REG:-US}
MCS=${MCS:-1}
TXPOW=${TXPOW:-1500}
NPKTS=${NPKTS:-3000}
PAYLOAD=${PAYLOAD:-100}
DELAY=${DELAY:-1000}
SUPP=$HOME/linux-80211n-csitool-supplementary

MODE=check; SECS=20
case "${1:-}" in
  '') ;;
  --send) MODE=send;;
  --rx) MODE=rx; SECS=${2:-20};;
  *) echo "usage: $0 [--send | --rx [秒]]" >&2; exit 1;;
esac
case "$BW" in
  HT20) HT40BIT=0;;
  HT40+|HT40-) HT40BIT=0x800;;
  *) echo "!! BW='$BW' は不可。HT20 / HT40+ / HT40- のいずれか" >&2; exit 1;;
esac
RATE=${RATE:-$(printf '0x%x' $((0x4100 | HT40BIT | MCS)))}
FREQ=$((5000 + 5 * CH)); [ "$CH" -le 14 ] && FREQ=$((2407 + 5 * CH))

ok() { echo "  [OK] $*"; }
ng() { echo "  [NG] $*"; NG=$((NG + 1)); }
info() { echo "       $*"; }
NG=0

echo "=== 1. 静的チェック ==="
[ "$(uname -r)" = "3.5.7+" ] && ok "kernel 3.5.7+" || ng "kernel $(uname -r) (3.5.7+ で起動していない)"
lspci | grep -qi 'WiFi Link 5300' && ok "Intel 5300 検出" || { ng "Intel 5300 が lspci に無い"; lspci | grep -iE 'network|wireless' | sed 's/^/       /'; }
modinfo iwlwifi 2>/dev/null | grep -q connector_log && ok "CSI 対応ドライバ" || ng "iwlwifi に connector_log が無い"

MISS=
for k in DEBUG_FS MAC80211_DEBUGFS IWLWIFI_DEBUG IWLWIFI_DEBUGFS; do
  grep -q "^CONFIG_$k=y" "/boot/config-$(uname -r)" 2>/dev/null || MISS="$MISS $k"
done
[ -z "$MISS" ] && ok "debugfs 4 項目 =y" || ng "kernel config 未設定:$MISS (monitor_tx_rate が出ない。カーネル再ビルド)"

OTHERS=$(ls /lib/firmware/iwlwifi-5000-*.ucode 2>/dev/null | grep -v 'iwlwifi-5000-2.ucode$')
readlink /lib/firmware/iwlwifi-5000-2.ucode 2>/dev/null | grep -q sigcomm2010 && ok "CSI ファームのリンク" || ng "iwlwifi-5000-2.ucode が sigcomm2010 を指していない"
[ -z "$OTHERS" ] && ok "標準ファームは退避済み" || ng "標準ファームが残っている: $(echo $OTHERS)"

ls /sbin/crda >/dev/null 2>&1 && ok "crda" || ng "crda が無い (iw reg set が効かず、UNII-3 が passive のままになる)"
ls /lib/crda/regulatory.bin /usr/lib/crda/regulatory.bin 2>/dev/null | grep -q . && ok "regulatory.bin" || ng "regulatory.bin が無い (wireless-regdb 未導入)"
sudo rfkill list wifi 2>/dev/null | grep -q 'blocked: yes' && ng "rfkill でブロック中 (sudo rfkill unblock wifi / 物理スイッチ)" || ok "rfkill"

if [ "$MODE" != rx ]; then
  [ -x "$SUPP/injection/random_packets" ] && ok "random_packets" || ng "random_packets が無い (LORCON 未導入のまま RX 専用になっている)"
  [ -x "$HOME/tx_capture.sh" ] || [ -x "$HOME/tx_setup.sh" ] && ok "TX スクリプト" || ng "~/tx_capture.sh も ~/tx_setup.sh も無い"
fi

echo "=== 2. 無線設定: ch$CH $BW / reg $REG / rate $RATE ==="
sudo service network-manager stop 2>/dev/null
sudo iw dev mon0 del 2>/dev/null
sudo modprobe -r iwlwifi mac80211 cfg80211 2>/dev/null
[ "$MODE" = rx ] && sudo modprobe iwlwifi connector_log=0x1 || sudo modprobe iwlwifi
sleep 3
dmesg | grep -iE 'loaded firmware version|Direct firmware|request.*firmware' | tail -2 | sed 's/^/       /'

info "無線 IF: $(iw dev | awk '/Interface/{print $2}' | tr '\n' ' ') (run_experiment.sh / rx_setup.sh / tx_setup.sh の既定は wlan1)"
IF=${IF:-$(iw dev | awk '/Interface/{print $2; exit}')}
[ -n "$IF" ] || { ng "無線インタフェースが無い"; echo "NG=$NG"; exit 1; }

sudo iw reg set "$REG"
sleep 3
iw reg get | grep -q "country $REG" && ok "regdomain $REG" || ng "regdomain が $REG にならない: $(iw reg get | grep country)"

LINE=$(iw list | grep -E "^[[:space:]]*\* $FREQ MHz")
info "$LINE"
if [ -z "$LINE" ]; then
  ng "$FREQ MHz がカードのチャンネル一覧に無い"
elif echo "$LINE" | grep -qiE 'passive|no IBSS|radar|disabled|no IR'; then
  ng "ch$CH に送信禁止フラグ。mac80211 が注入を黙って全部捨てる (net/mac80211/tx.c monitor_start_xmit)"
else
  ok "ch$CH に送信禁止フラグなし"
fi

if [ "$MODE" = rx ]; then
  sudo ifconfig "$IF" down
  sudo iwconfig "$IF" mode monitor
  sudo ifconfig "$IF" up
  sleep 3
  CAPIF=$IF
else
  sudo ifconfig "$IF" down
  sudo iw dev "$IF" interface add mon0 type monitor
  sudo iw dev "$IF" del
  sudo ifconfig mon0 up
  sleep 3
  CAPIF=mon0
fi
sudo iw dev "$CAPIF" set channel "$CH" "$BW" && ok "set channel" || ng "set channel $CH $BW 失敗"
# 3.5.7 の iw dev info は channel を出さないので iwconfig で見る
info "周波数: $(iwconfig "$CAPIF" 2>/dev/null | grep -o '[0-9.]* GHz')"

if [ "$MODE" = rx ]; then
  echo "=== 3. 受信 ${SECS} 秒 (この間に TX 機で送信) ==="
  [ -x "$SUPP/netlink/log_to_file" ] || ng "log_to_file が無い"
  TMP=$(mktemp -d)
  sudo timeout -s INT "$SECS" "$SUPP/netlink/log_to_file" "$TMP/csi.dat" >/dev/null 2>&1 &
  LOGPID=$!
  sudo timeout "$SECS" tcpdump -i "$IF" -nn 2>/dev/null > "$TMP/dump.txt"
  wait $LOGPID
  ALL=$(wc -l < "$TMP/dump.txt")
  INJ=$(grep -c 16:ea "$TMP/dump.txt")
  HT=$(grep -i mcs "$TMP/dump.txt" | grep -c 16:ea)
  CSI=$(stat -c%s "$TMP/csi.dat" 2>/dev/null || echo 0)
  echo "  全フレーム $ALL / 注入MAC $INJ / うち HT(MCS) $HT / CSI $CSI byte"
  if [ "$INJ" -eq 0 ]; then
    echo "  → 空中で受かっていない: TX が出ていない、ch/BW 不一致、TX のアンテナ未接続のどれか"
  elif [ "$HT" -eq 0 ]; then
    echo "  → 非 HT で届いている: TX の monitor_tx_rate が効いていない (CSI は HT にしか付かない)"
  elif [ "$CSI" -eq 0 ]; then
    echo "  → HT は届くが CSI 0: RX 側の問題 (標準ファームを読んでいる / connector ID 不一致)"
  else
    echo "  → 受信 OK。TX→RX の経路は生きている"
  fi
  sudo rm -rf "$TMP"
  echo "NG=$NG"
  exit 0
fi

sudo iw dev mon0 set txpower fixed "$TXPOW"
RF=$(sudo find /sys/kernel/debug -name monitor_tx_rate | head -1)
if [ -n "$RF" ]; then
  echo "$RATE" | sudo tee "$RF" >/dev/null
  GOT=$(sudo cat "$RF")
  [ "$GOT" = "$RATE" ] && ok "monitor_tx_rate = $GOT" || ng "monitor_tx_rate 読み戻し $GOT (設定 $RATE)"
else
  ng "monitor_tx_rate が無い。レート固定なし = 非 HT で飛ぶので RX に CSI が付かない"
fi

if [ "$MODE" = check ]; then
  echo "=== 点検のみで終了 (NG=$NG)。送信テストは --send ==="
  exit 0
fi

echo "=== 3. 送信 $NPKTS 発 ==="
[ -x "$SUPP/injection/random_packets" ] || { echo "!! random_packets が無いので送信テスト不可"; exit 1; }
F=$(sudo find /sys/kernel/debug/ieee80211 -name failed_count | head -1)
T=$(sudo find /sys/kernel/debug/ieee80211 -name transmitted_fragment_count | head -1)
CL=$(sudo find /sys/kernel/debug -name clear_ucode_statistics | head -1)
UT=$(sudo find /sys/kernel/debug -name ucode_tx_stats | head -1)
RE=$(sudo find /sys/kernel/debug -name reply_tx_error | head -1)
count() { echo $(( $(sudo cat "$F") + $(sudo cat "$T") )); }

C0=$(count)
[ -n "$CL" ] && echo 1 | sudo tee "$CL" >/dev/null
( cd "$SUPP/injection" && sudo ./random_packets "$NPKTS" "$PAYLOAD" 1 "$DELAY" ) >/dev/null
RET=$?
sleep 1
[ -n "$CL" ] && echo 1 | sudo tee "$CL" >/dev/null
sleep 1
C1=$(count)
DONE=$((C1 - C0))

echo "  random_packets 終了コード: $RET"
echo "  ファーム完了報告: $DONE / $NPKTS 発 (failed_count + transmitted_fragment_count の増分)"
[ -n "$UT" ] && sudo cat "$UT" | grep -m1 -E 'preamble:' | sed 's/^[[:space:]]*/       /'
[ -n "$RE" ] && sudo cat "$RE" | awk -F'[:\t ]+' '$NF+0 > 0' | sed 's/^/       /'

if [ "$RET" -ne 0 ]; then
  echo "  → random_packets 自体が失敗: LORCON / mon0 を確認"
elif [ "$DONE" -eq 0 ]; then
  echo "  → ファームまで届いていない: mac80211 で破棄。上のチャンネルフラグ NG を直す"
elif [ $((DONE * 10)) -lt $((NPKTS * 9)) ]; then
  echo "  → 一部しか完了していない: 上の TX エラー内訳を確認"
else
  echo "  → カードは送信処理を完了。RX で受からないならアンテナ (rate $RATE のポートが未接続) か ch/BW 不一致"
  echo "    RX 機で ~/tx_diag.sh --rx を動かして確認する。アンテナは RATE=0x8901 / 0x10901 を試す"
fi
echo "NG=$NG"
