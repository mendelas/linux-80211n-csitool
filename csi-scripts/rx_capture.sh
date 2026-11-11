#!/bin/bash
# Intel 5300 CSI RX
#
# 使い方:  ~/rx_capture.sh [--resetup] <ラベル>
#   例) ~/rx_capture.sh --resetup st0      起動後・CH/BW 変更後に 1 回だけ (ドライバ再読込 + monitor + ch)
#       ~/rx_capture.sh walk01             以後の収録: 無線の状態を確認して保存するだけ (再読込しない)
#       CH=48 BW=HT20 ~/rx_capture.sh --resetup walk01_ch48
#
# ★ ドライバ (iwlwifi) を読み込み直すたびに 5300 が初期化され、RX チェーン間の位相が π 単位で
#    変わり得る。だから再読込は --resetup のときだけ。付けない収録は確認のみで、準備できていなければ
#    止まって --resetup を案内する。同じ設置で撮る一連の収録は、最初の 1 本だけ --resetup を付ける。
# ★ CH と BW は TX と完全一致させること。ズレると1パケットも受からない (エラーも出ない)
# 保存先: ~/csi_data/YYYYMMDD/YYYYMMDD_HHMMSS_<ラベル>.csi
#         ~/csi_data/YYYYMMDD/rx_capture.log に 1 収録 1 行 (ifindex が同じ = 同じ NIC 初期化)

RESETUP=0
[ "${1:-}" = --resetup ] && { RESETUP=1; shift; }
CH=${CH:-157}                # TX と一致必須 (157 HT40+ = 中心5795MHz)
BW=${BW:-HT40+}              # TX と一致必須。HT20 / HT40+ / HT40- のみ
REG=${REG:-US}
case "$BW" in HT20|HT40+|HT40-) ;; *) echo "!! BW='$BW' は不可。HT20 / HT40+ / HT40- のいずれか" >&2; exit 1;; esac
LABEL=${1:-csi}

echo "=== RX: ch$CH $BW / label=$LABEL / $([ $RESETUP = 1 ] && echo 'ドライバ再読込あり (--resetup)' || echo '再読込なし (確認のみ)') ==="

if [ $RESETUP = 1 ]; then
  sudo service network-manager stop 2>/dev/null
  sudo modprobe -r iwlwifi mac80211 cfg80211 2>/dev/null
  sudo modprobe iwlwifi connector_log=0x1
  sleep 3
fi

IF=${IF:-$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')}
[ -n "$IF" ] || { echo "!! 無線インタフェースが見つからない (起動直後なら: ~/rx_capture.sh --resetup $LABEL)" >&2; exit 1; }
echo "IF=$IF"

if [ $RESETUP = 1 ]; then
  sudo iw reg set "$REG"
  sleep 3
  sudo ifconfig "$IF" down
  sudo iwconfig "$IF" mode monitor
  sudo ifconfig "$IF" up
  sleep 3
  sudo iw dev "$IF" set channel "$CH" "$BW" || { echo "!! set channel 失敗"; exit 1; }
fi

# --- 確認 (読むだけ。再読込も down も再チューンもしない)。multi-rx/radio_check.sh rx と同じ項目 ---
BAD=(); NOTE=
CL=$(cat /sys/module/iwlwifi/parameters/connector_log 2>/dev/null)
if [ ! -d /sys/module/iwlwifi ]; then BAD+=("iwlwifi が読み込まれていない")
elif [ -z "$CL" ] || [ "$CL" = 0 ]; then BAD+=("iwlwifi が connector_log=${CL:-?} で読み込まれている (CSI が出ない)")
fi
INFO=$(iw dev "$IF" info 2>/dev/null)
# 803 = ARPHRD_IEEE80211_RADIOTAP (monitor インタフェースのリンク種別)
grep -q 'type monitor' <<<"$INFO" || [ "$(cat "/sys/class/net/$IF/type" 2>/dev/null)" = 803 ] || BAD+=("$IF が monitor モードでない")
(( $(cat "/sys/class/net/$IF/flags" 2>/dev/null || echo 0) & 1 )) || BAD+=("$IF が down")
WANT_F=$(( CH <= 14 ? 2407 + 5 * CH : 5000 + 5 * CH ))
CHL=$(grep -m1 -E '^[[:space:]]*channel [0-9]+' <<<"$INFO")
if [ -n "$CHL" ]; then
  # "channel 157 (5785 MHz), type: HT40+" (3.5 系) / "..., width: 40 MHz, center1: 5795 MHz" (新しい iw)
  GOT_CH=$(sed -nE 's/.*channel ([0-9]+) .*/\1/p' <<<"$CHL")
  TYPE=$(sed -nE 's/.*type: ([^,]+).*/\1/p' <<<"$CHL"); TYPE=${TYPE// /}
  WIDTH=$(sed -nE 's/.*width: ([0-9]+) MHz.*/\1/p' <<<"$CHL")
  C1=$(sed -nE 's/.*center1: ([0-9]+) MHz.*/\1/p' <<<"$CHL")
  if [ -n "$TYPE" ]; then GOT_BW=$TYPE
  elif [ "$WIDTH" = 20 ]; then grep -q 'no HT' <<<"$CHL" && GOT_BW=NOHT || GOT_BW=HT20
  elif [ "$WIDTH" = 40 ] && [ "$C1" = $((WANT_F + 10)) ]; then GOT_BW=HT40+
  elif [ "$WIDTH" = 40 ] && [ "$C1" = $((WANT_F - 10)) ]; then GOT_BW=HT40-
  else GOT_BW="width${WIDTH:-?}/center1:${C1:-?}"
  fi
  { [ "$GOT_CH" = "$CH" ] && [ "$GOT_BW" = "$BW" ]; } || BAD+=("$IF は ch$GOT_CH $GOT_BW (指定は ch$CH $BW)")
else
  # kernel 3.5.7 の iw は channel 行を出さない: iwconfig の周波数だけ確認 (帯域幅は確認できない)
  GHZ=$(iwconfig "$IF" 2>/dev/null | grep -o 'Frequency[:=][0-9.]*' | grep -o '[0-9.]*$')
  GOT_F=$(awk -v g="$GHZ" 'BEGIN { if (g != "") printf "%d", g * 1000 + 0.5 }')
  if [ -z "$GOT_F" ]; then BAD+=("$IF のチャンネルが読めない (iw dev info にも iwconfig にも出ない)")
  elif [ "$GOT_F" != "$WANT_F" ]; then BAD+=("$IF は $GOT_F MHz (指定は ch$CH = $WANT_F MHz)")
  else NOTE=" (帯域幅 $BW は未確認: iw が channel 行を出さない)"
  fi
fi
if [ ${#BAD[@]} -gt 0 ]; then
  echo "!! 無線の準備ができていない:" >&2
  for b in "${BAD[@]}"; do echo "     - $b" >&2; done
  [ $RESETUP = 1 ] || echo "   起動後・CH/BW 変更後・TX として使った後は 1 回:  CH=$CH BW=$BW ~/rx_capture.sh --resetup $LABEL" >&2
  exit 1
fi
IFINDEX=$(cat "/sys/class/net/$IF/ifindex")
# ifindex はドライバ再読込のたびに変わる: 収録間で同じ番号 = 同じ NIC 初期化 (π の型が共通)
echo "--- ready: $IF ch$CH $BW monitor up connector_log=$CL ifindex $IFINDEX$NOTE ---"

DIR="$HOME/csi_data/$(date +%Y%m%d)"
mkdir -p "$DIR"
OUT="$DIR/$(date +%Y%m%d_%H%M%S)_${LABEL}.csi"
printf '%s\t%s\tch%s %s\t%s\tifindex %s\t%s\n' "$(date +%Y%m%d_%H%M%S)" "$LABEL" "$CH" "$BW" \
  "$([ $RESETUP = 1 ] && echo resetup || echo check)" "$IFINDEX" "$(basename "$OUT")" >> "$DIR/rx_capture.log"
echo "=== save: $OUT  (Ctrl+C で停止) ==="
sudo ~/linux-80211n-csitool-supplementary/netlink/log_to_file "$OUT"
