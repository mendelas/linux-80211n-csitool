#!/bin/bash
# Intel 5300 CSI injection TX
#
# 使い方:  ~/tx_capture.sh [電力] [MCS]
#   例) ~/tx_capture.sh                 → 既定 (15dBm, MCS1)
#       ~/tx_capture.sh 13dBm           → 13dBm
#       ~/tx_capture.sh 13dBm 3         → 13dBm, MCS3 (16-QAM 1/2)
#       CH=48 BW=HT20 ~/tx_capture.sh 10dBm
#
# 電力: 15 / 15dBm / 1500(mBm) いずれの書き方でも可。31以上は mBm と解釈。
# MCS (1ストリーム): 0=BPSK1/2 1=QPSK1/2 2=QPSK3/4 3=16QAM1/2
#                    4=16QAM3/4 5=64QAM2/3 6=64QAM3/4 7=64QAM5/6
#   ※8以上は2ストリームになり CSI 行列の形が変わるので使わないこと
# RATE は BW と MCS から自動計算 (ant A + HT + HT40bit + MCS)。直接指定も可。

CH=${CH:-157}                # 157 HT40+ = 157+161 → 中心5795MHz (UNII-3, 要免許)
BW=${BW:-HT40+}              # HT20 / HT40+ / HT40- のみ。★"HT40"単体は iw が受け付けない
# ▼ 変調方式はここを編集 (第2引数 or MCS=n でも指定可)。0-7 のみ (8以上は2ストリーム化で不可)
#   ┌ MCS ┬ 変調      ┬ 符号化率 ┐
#   │  0  │ BPSK      │ 1/2      │
#   │  1  │ QPSK      │ 1/2      │ ← 既定
#   │  2  │ QPSK      │ 3/4      │
#   │  3  │ 16-QAM    │ 1/2      │
#   │  4  │ 16-QAM    │ 3/4      │
#   │  5  │ 64-QAM    │ 2/3      │
#   │  6  │ 64-QAM    │ 3/4      │
#   │  7  │ 64-QAM    │ 5/6      │
#   └─────┴───────────┴──────────┘
MCS=${MCS:-1}
TXPOW=${TXPOW:-1500}         # mBm = dBm x100。下限0dBm、上限はカードのEEPROM値
NPKTS=${NPKTS:-200000}
PAYLOAD=${PAYLOAD:-10}
DELAY=${DELAY:-1000}         # us。1000 → 1000pkt/s
REG=${REG:-US}               # UNII-3(149-165) には US が必要

# --- 第1引数: 送信電力 ---
if [ -n "${1:-}" ]; then
  N=$(echo "$1" | tr -d 'dDbBmM ')
  case "$N" in ''|*[!0-9]*) echo "usage: $0 [<dBm>|<mBm>] [<MCS 0-7>]"; exit 1;; esac
  if [ "$N" -le 30 ]; then TXPOW=$((N*100)); else TXPOW=$N; fi
fi
# --- 第2引数: MCS ---
if [ -n "${2:-}" ]; then
  case "$2" in ''|*[!0-9]*) echo "usage: $0 [<dBm>|<mBm>] [<MCS 0-7>]"; exit 1;; esac
  MCS=$2
fi
[ "$MCS" -le 7 ] || { echo "!! MCS=$MCS は2ストリーム。CSI行列の形が変わるので 0-7 に" >&2; exit 1; }

# --- BW 検証: "HT40" 単体は iw がエラーにするが、従来スクリプトは検知せず先へ進んでいた ---
case "$BW" in
  HT20|HT40+|HT40-) ;;
  *) echo "!! BW='$BW' は不可。HT20 / HT40+ / HT40- のいずれか" >&2; exit 1;;
esac

# --- RATE を BW と MCS から自動計算 ---
#   HT20 → 0x410<MCS> / HT40 → 0x490<MCS>  (例: HT40+ MCS3 → 0x4903)
#   自分で直接指定したい場合はこの下の行を  RATE=0x4903  のように書き換えるか、
#   実行時に  RATE=0x4903 ~/tx_capture.sh  と付ける (指定があれば自動計算より優先)
case "$BW" in HT40*) HT40BIT=0x800;; *) HT40BIT=0;; esac
RATE=${RATE:-$(printf '0x%x' $((0x4100 | HT40BIT | MCS)))}

echo "=== TX: ch$CH $BW / MCS$MCS / RATE=$RATE / $((TXPOW/100))dBm (${TXPOW}mBm) ==="

sudo service network-manager stop 2>/dev/null
sudo iw dev mon0 del 2>/dev/null
sudo modprobe -r iwlwifi mac80211 cfg80211 2>/dev/null
sudo modprobe iwlwifi
sleep 3

IF=${IF:-$(iw dev | awk '/Interface/{print $2; exit}')}
[ -n "$IF" ] || { echo "!! 無線インタフェースが見つからない" >&2; exit 1; }
echo "IF=$IF"

sudo iw reg set "$REG"
sleep 3
sudo ifconfig "$IF" down
sudo iw dev "$IF" interface add mon0 type monitor
sudo iw dev "$IF" del
sudo ifconfig mon0 up
sleep 3

sudo iw dev mon0 set channel "$CH" "$BW" || { echo "!! set channel 失敗" >&2; exit 1; }
# 電力は set channel の後に。前に置くとドライバに defer される
sudo iw dev mon0 set txpower fixed "$TXPOW"

echo "--- 実際の設定 (width と center1 を必ず確認) ---"
iw dev mon0 info | grep -E 'channel|txpower'

RF=$(sudo find /sys/kernel/debug -name monitor_tx_rate | head -1)
[ -n "$RF" ] || { echo "!! monitor_tx_rate が無い (CONFIG_IWLWIFI_DEBUGFS 無効)" >&2; exit 1; }
echo "$RATE" | sudo tee "$RF" >/dev/null
echo "--- tx rate ---"; sudo cat "$RF"; echo

echo "=== injecting $NPKTS pkts (Ctrl+C で停止) ==="
cd ~/linux-80211n-csitool-supplementary/injection || exit 1
sudo ./random_packets "$NPKTS" "$PAYLOAD" 1 "$DELAY"
