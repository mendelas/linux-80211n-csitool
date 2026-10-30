#!/bin/bash
# Intel 5300 CSI injection TX
#
# Usage:  ~/tx_capture.sh [power] [MCS]
#   e.g.  ~/tx_capture.sh                 -> defaults (15dBm, MCS1)
#         ~/tx_capture.sh 13dBm           -> 13dBm
#         ~/tx_capture.sh 13dBm 3         -> 13dBm, MCS3 (16-QAM 1/2)
#         CH=48 BW=HT20 ~/tx_capture.sh 10dBm
#
# Power: 15 / 15dBm / 1500(mBm) are all accepted. 31 or more is taken as mBm.
# MCS (1 spatial stream): 0=BPSK1/2 1=QPSK1/2 2=QPSK3/4 3=16QAM1/2
#                         4=16QAM3/4 5=64QAM2/3 6=64QAM3/4 7=64QAM5/6
#   * MCS 8 and above use 2 spatial streams and change the shape of the CSI matrix -- do not use.
# RATE is derived from BW and MCS (ant A + HT + HT40 bit + MCS). It can also be given directly.

CH=${CH:-157}                # 157 HT40+ = 157+161 -> center 5795MHz (UNII-3, licence required)
BW=${BW:-HT40+}              # HT20 / HT40+ / HT40- only. * a bare "HT40" is rejected by iw
# v Edit the modulation here (or pass it as the 2nd argument / MCS=n). 0-7 only (8+ = 2 streams, not allowed)
#   +-----+-----------+-------------+
#   | MCS | modulation| coding rate |
#   |  0  | BPSK      | 1/2         |
#   |  1  | QPSK      | 1/2         | <- default
#   |  2  | QPSK      | 3/4         |
#   |  3  | 16-QAM    | 1/2         |
#   |  4  | 16-QAM    | 3/4         |
#   |  5  | 64-QAM    | 2/3         |
#   |  6  | 64-QAM    | 3/4         |
#   |  7  | 64-QAM    | 5/6         |
#   +-----+-----------+-------------+
MCS=${MCS:-1}
TXPOW=${TXPOW:-1500}         # mBm = dBm x100. Minimum 0dBm; the maximum is the card's EEPROM limit
NPKTS=${NPKTS:-200000}
PAYLOAD=${PAYLOAD:-10}
DELAY=${DELAY:-1000}         # us. 1000 -> 1000 pkt/s
REG=${REG:-US}               # UNII-3 (149-165) needs US

# --- 1st argument: TX power ---
if [ -n "${1:-}" ]; then
  N=$(echo "$1" | tr -d 'dDbBmM ')
  case "$N" in ''|*[!0-9]*) echo "usage: $0 [<dBm>|<mBm>] [<MCS 0-7>]"; exit 1;; esac
  if [ "$N" -le 30 ]; then TXPOW=$((N*100)); else TXPOW=$N; fi
fi
# --- 2nd argument: MCS ---
if [ -n "${2:-}" ]; then
  case "$2" in ''|*[!0-9]*) echo "usage: $0 [<dBm>|<mBm>] [<MCS 0-7>]"; exit 1;; esac
  MCS=$2
fi
[ "$MCS" -le 7 ] || { echo "!! MCS=$MCS uses 2 spatial streams and changes the CSI matrix shape. Use 0-7" >&2; exit 1; }

# --- BW check: iw rejects a bare "HT40", but the old script did not notice and carried on ---
case "$BW" in
  HT20|HT40+|HT40-) ;;
  *) echo "!! BW='$BW' is not allowed. Use HT20 / HT40+ / HT40-" >&2; exit 1;;
esac

# --- Derive RATE from BW and MCS ---
#   HT20 -> 0x410<MCS> / HT40 -> 0x490<MCS>  (e.g. HT40+ MCS3 -> 0x4903)
#   To set it by hand, either change the line below to  RATE=0x4903  or run
#   RATE=0x4903 ~/tx_capture.sh  (an explicit value takes precedence over the derived one)
case "$BW" in HT40*) HT40BIT=0x800;; *) HT40BIT=0;; esac
RATE=${RATE:-$(printf '0x%x' $((0x4100 | HT40BIT | MCS)))}

echo "=== TX: ch$CH $BW / MCS$MCS / RATE=$RATE / $((TXPOW/100))dBm (${TXPOW}mBm) ==="

sudo service network-manager stop 2>/dev/null
sudo iw dev mon0 del 2>/dev/null
sudo modprobe -r iwlwifi mac80211 cfg80211 2>/dev/null
sudo modprobe iwlwifi
sleep 3

IF=${IF:-$(iw dev | awk '/Interface/{print $2; exit}')}
[ -n "$IF" ] || { echo "!! no wireless interface found" >&2; exit 1; }
echo "IF=$IF"

sudo iw reg set "$REG"
sleep 3
sudo ifconfig "$IF" down
sudo iw dev "$IF" interface add mon0 type monitor
sudo iw dev "$IF" del
sudo ifconfig mon0 up
sleep 3

sudo iw dev mon0 set channel "$CH" "$BW" || { echo "!! set channel failed" >&2; exit 1; }
# txpower must come after set channel; set before it, the driver defers it
sudo iw dev mon0 set txpower fixed "$TXPOW"

echo "--- actual settings (always check width and center1) ---"
# Note: kernel 3.5.7 does not report channel/txpower in `iw dev info`, so this block may be empty.
#       Check the frequency with `iwconfig mon0` instead.
iw dev mon0 info | grep -E 'channel|txpower'

RF=$(sudo find /sys/kernel/debug -name monitor_tx_rate | head -1)
[ -n "$RF" ] || { echo "!! monitor_tx_rate not found (CONFIG_IWLWIFI_DEBUGFS is disabled)" >&2; exit 1; }
echo "$RATE" | sudo tee "$RF" >/dev/null
echo "--- tx rate ---"; sudo cat "$RF"; echo

echo "=== injecting $NPKTS pkts (Ctrl+C to stop) ==="
cd ~/linux-80211n-csitool-supplementary/injection || exit 1
sudo ./random_packets "$NPKTS" "$PAYLOAD" 1 "$DELAY"
