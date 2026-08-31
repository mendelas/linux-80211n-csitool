# Intel 5300 CSI Tool セットアップ手順（Ubuntu 14.04）

Linux 802.11n CSI Tool（Halperin et al., University of Washington）を、
**Intel 5300 NIC を積んだ古いノート PC**（例: HP ProBook 6570b）で
動かすための実践メモ。ツール本体は **無改変** で使う前提。

> 対象リポジトリ: このリポジトリ（= Linux 3.5.7 カーネルソース + CSI 対応 iwlwifi ドライバ）
> 別途必要: [linux-80211n-csitool-supplementary](https://github.com/dhalperi/linux-80211n-csitool-supplementary)（ファームウェア・記録/解析ツール）
>
> 実機ごとの進捗記録: PC4/5/6 は [SETUP_PC456_JA.md](SETUP_PC456_JA.md)（NIC 換装前までの作業記録＋換装後の残作業）

---

## 0. 前提・ハードウェア要件

- **Intel 5300（IWL5300）必須**。これ以外の NIC では CSI は取れない。
  ```bash
  lspci | grep -i network   # "Intel ... WiFi Link 5300" が出ること
  ```
- OS: Ubuntu 14.04 LTS（古い PC に新規インストール）。

---

## 1. 最大のハマりどころ：カーネルのバージョン

このドライバは **Linux 3.5.7** のソースそのもの（`Makefile` の `VERSION=3 PATCHLEVEL=5 SUBLEVEL=7`）で、
**カーネル 3.5 時代の古い API をそのまま使っている**（バージョン分岐 `#ifdef` は一切なし）。
そのため、新しすぎても古すぎてもコンパイルが通らない。

| 試したカーネル | 結果 | 原因 |
|---|---|---|
| 4.4（14.04.5 HWE） | ✗ ビルド不可 | API が大きく変化 |
| 3.13（14.04 標準） | ✗ `struct ieee80211_conf has no member 'channel'` | 3.8 で `conf->channel` 廃止 |
| 3.4.113（mainline） | ✗ `struct <anonymous> has no member 'antenna'` | 3.5 にある `status.antenna` が無い |
| **3.5.7（このリポジトリを丸ごとビルド）** | **✓ 成功** | 完全一致 |

**結論:** 3.5 系カーネルが必要。だが Ubuntu mainline アーカイブから 3.5 系は削除済み（3.4.113 しか残っていない）。
→ **このリポジトリ自体が 3.5.7 カーネルなので、これを丸ごとビルドして起動する**のが正解。
これがこのツール本来の使い方（`make_distribution.sh` / `install_distribution.sh` 同梱が傍証）。

> 補足: ビルド方法は2通り。
> - **(A) モジュールだけ単体ビルド** (`make -C /lib/modules/.../build M=...`) … 動作中カーネルが 3.5 系である必要あり → 3.5 系が入手不能なので不採用
> - **(B) リポジトリを丸ごとビルド** (`make` → `make install`) … 動作中カーネルが何であれ 3.5.7 が出来る → **こちらを採用**
> (B) なら、ビルド時にどのカーネルで起動していても結果は同じ。

---

## 2. カーネル(3.5.7)のビルドとインストール

```bash
# 2-1. ビルド依存
sudo apt-get install build-essential libncurses5-dev git-core

# 2-2. 設定ファイル(.config) を現在のカーネルから流用
cd ~/linux-80211n-csitool
cp /boot/config-$(uname -r) .config

# ★ injection に必須の debug/debugfs を有効化（これを忘れると monitor_tx_rate が出ない）
scripts/config --enable DEBUG_FS
scripts/config --enable MAC80211_DEBUGFS
scripts/config --enable IWLWIFI_DEBUG
scripts/config --enable IWLWIFI_DEBUGFS

yes '' | make oldconfig          # 質問はすべてデフォルトで自動回答
# 確認（4つとも =y であること）
grep -E 'CONFIG_DEBUG_FS=|CONFIG_MAC80211_DEBUGFS=|CONFIG_IWLWIFI_DEBUG=|CONFIG_IWLWIFI_DEBUGFS=' .config

# 2-3. ビルド（古い PC で 30〜60 分）
make -j$(nproc)
# 最後に "Kernel: arch/x86/boot/bzImage is ready" が出れば成功

# 2-4. インストール（sudo 必須）
sudo make modules_install
sudo make install                # vmlinuz/initrd 配置 + update-grub 自動実行

# 2-5. 再起動して 3.5.7 で起動
sudo reboot
# GRUB → "Advanced options for Ubuntu" → "Linux 3.5.7+" を選択
```

> ⚠️ 起動時の GRUB で **必ず 3.5.7+ を選ぶ**こと。デフォルト起動だと元のカーネルに戻ってしまう。
> カーネル名が `3.5.7+`（末尾 `+`）になるのは git ツリーからビルドした正常な挙動。

### 確認

```bash
uname -r                              # 3.5.7+ であること
modinfo iwlwifi | grep -i connector   # parm: connector_log が出れば CSI 対応ドライバ ✓
lsmod | grep iwlwifi                  # 読み込まれていること
```

`connector_log` が出ない場合 → 3.5.7+ ではない別カーネルで起動している。GRUB で選び直す。

---

## 3. CSI 対応ファームウェアと記録ツール

```bash
cd ~
git clone https://github.com/dhalperi/linux-80211n-csitool-supplementary.git

# CSI 対応ファームウェアを配置（標準 FW は .orig に退避）
for f in /lib/firmware/iwlwifi-5000-*.ucode; do sudo mv "$f" "$f.orig"; done
sudo cp ~/linux-80211n-csitool-supplementary/firmware/iwlwifi-5000-2.ucode.sigcomm2010 /lib/firmware/
sudo ln -s iwlwifi-5000-2.ucode.sigcomm2010 /lib/firmware/iwlwifi-5000-2.ucode

# ★ connector ID をカーネルに合わせる（フルカーネルビルド時に必須）
#   このツリーは CN_NETLINK_USERS=10 → CN_IDX_IWLAGN=10+0xf=25 で CSI を送る。
#   一方 log_to_file は libc ヘッダ(/usr/include/linux/connector.h, Ubuntu14.04 では 11)
#   を使うため 26 になり、netlink グループが噛み合わず CSI が 0 バイトになる。
#   → log_to_file 側を 10 に固定して一致させる。
sed -i 's@CN_NETLINK_USERS + 0xf@10 + 0xf@' ~/linux-80211n-csitool-supplementary/netlink/iwl_connector.h

# 記録ツール log_to_file をビルド
make -C ~/linux-80211n-csitool-supplementary/netlink
```

---

## 4. CSI の記録

CSI は「**受信した 802.11n(HT) パケット**」に対して記録される。送信側（電波を出す相手）が必要。

### 4-A. AP に接続して取る方式（簡単だが注意あり）

```bash
sudo modprobe -r iwlwifi
sudo modprobe iwlwifi connector_log=0x1
# → 普通に Wi-Fi 接続 → ルーター宛に ping を流し続ける
sudo ~/linux-80211n-csitool-supplementary/netlink/log_to_file ~/csi.dat
# 数秒〜十数秒で Ctrl+C
ls -l ~/csi.dat   # サイズ > 0 なら記録成功
```

> ⚠️ **既知の問題:** CSI 改造ファームウェアは AP への **アソシエーションに失敗する**ことがある
> （`wlan: authenticated` の直後に `CTRL-EVENT-SSID-TEMP-DISABLED auth_failures=1` で切断）。
> 認証は通るがアソシエーションで落ちるパターン。公共 AP では特に弾かれやすい。
> 自前ルーター/テザリングでも失敗するなら → **4-B のモニターモードに切り替える**。

### 4-B. injection 方式（2台の Intel 5300・推奨）

アソシエーション問題を完全に回避できる、CSI 収集の正攻法。**両機とも Intel 5300 + CSI tool 導入済み**が前提。

```
[送信5300(TX)] ──── 802.11n HT パケット ───▶ [受信5300(RX, モニターモード)]
 random_packets で注入                          受信 CSI を log_to_file で記録
```

> ⚠️ **インターフェース名:** 公式スクリプトは `wlan0` 前提。`iwconfig` で確認し、`wlan1` なら書き換える:
> ```bash
> cd ~/linux-80211n-csitool-supplementary/injection
> sed -i 's/wlan0/wlan1/g' setup_monitor_csi.sh setup_inject.sh
> ```

**送信側(TX)の事前ビルド（LORCON + random_packets）:**
```bash
sudo apt-get install libpcap-dev
cd ~ && git clone https://github.com/dhalperi/lorcon-old.git
cd lorcon-old && ./configure && make && sudo make install && sudo ldconfig
cd ~/linux-80211n-csitool-supplementary/injection && make
```

**受信側(RX) — CSI を記録:**
```bash
cd ~/linux-80211n-csitool-supplementary/injection
sudo ./setup_monitor_csi.sh 64 HT20          # モニターモード, ch64(5GHz), HT20
sudo ../netlink/log_to_file ~/csi.dat         # 記録開始（あとで Ctrl+C）
```

**送信側(TX) — パケット注入:**
```bash
cd ~/linux-80211n-csitool-supplementary/injection
sudo ./setup_inject.sh 64 HT20               # ★ RX と同じ ch/帯域に合わせる
echo 0x4101 | sudo tee $(sudo find /sys/kernel/debug -name monitor_tx_rate)   # 送信レート（find にも sudo 必須）
sudo ./random_packets 100000 100 1 1000      # 個数 長さ モード(1=注入MAC) 間隔µs
```

- `random_packets <個数> <長さ> <モード:0=自MAC/1=注入MAC> <間隔µs>`
- 疎通テストはまず少量で: `sudo ./random_packets 10 100 1`
- **送受信で channel と帯域を必ず一致**させること。ズレると1パケットも受からない。
- ここでの `64 HT20` は上流 README の例示にすぎない（ch64 は W53 = DFS で日本では送信不可）。
  **実際の運用は §4-C の標準設定（ch157 HT40+）と [csi-scripts/](csi-scripts/) のスクリプトに従う**こと。

> 5300 が1台しか無い場合は AP 接続方式(4-A)になるが、アソシエーション問題に当たりやすい。
> injection（5300×2）が最も確実。詳細は supplementary の `injection/README`。

---

## 4-C. 標準キャプチャ設定（ch157 HT40+ / 中心 5795 MHz）とスクリプト

実際に使うスクリプトは **このリポジトリの [csi-scripts/](csi-scripts/) が正**（以下の記述はその要約）。
以前この節に載せていたインライン版（ch48 固定・IF 引数）は古いので使わないこと。

```bash
wget https://raw.githubusercontent.com/mendelas/linux-80211n-csitool/csitool-stable/csi-scripts/tx_capture.sh -O ~/tx_capture.sh
wget https://raw.githubusercontent.com/mendelas/linux-80211n-csitool/csitool-stable/csi-scripts/rx_capture.sh -O ~/rx_capture.sh
chmod +x ~/tx_capture.sh ~/rx_capture.sh
```

### 標準設定

| 項目 | 値 | 備考 |
|---|---|---|
| 制御チャンネル | **157**（5785 MHz） | `CH` |
| 帯域幅 | **HT40+**（拡張ch=161/5805、**中心 5795 MHz**） | `BW`。★`HT40` 単体は `iw` が受け付けない |
| 規制ドメイン | `US` | UNII-3(149–165) をドライバ側で開放するため。`REG` |
| MCS | 1（QPSK 1/2、1ストリーム） | `MCS`。RATE は BW と MCS から自動計算（MCS1/HT40 → 0x4901） |
| 送信電力 | 15 dBm（1500 mBm） | `TXPOW`。第1引数でも指定可 |
| パケット | 200000 発 / 10 byte / 1000 µs 間隔（=1000 pkt/s、約 200 秒） | `NPKTS` `PAYLOAD` `DELAY` |
| インタフェース | 自動検出（`iw dev` の先頭） | `IF` で上書き可 |

> `ch157 HT40+` と `ch161 HT40-` は**同じ 157+161 ペア（中心 5795 MHz）**だが、主 20MHz（制御ch）が
> 逆になる。**送受で表記まで完全に一致**させること（`157 HT40+` に統一する）。

### 使い方

```bash
# ① RX 機（先に待機）  → ~/csi_data/YYYYMMDD/YYYYMMDD_HHMMSS_<ラベル>.csi
~/rx_capture.sh walk01

# ② TX 機
~/tx_capture.sh                 # 既定 15dBm / MCS1
~/tx_capture.sh 13dBm 3         # 13dBm, MCS3(16QAM 1/2)
CH=48 BW=HT40- REG=JP ~/rx_capture.sh walk01_ch48   # 設定変更は環境変数で（送受とも同じ値に）

# ③ RX を Ctrl+C → ls -l でサイズ >0 を確認
```

- MCS は **0–7（1ストリーム）のみ**。8 以上は 2 ストリームになり CSI 行列の形が変わる。
- 疎通テストは少量で: TX 側で `NPKTS=10 PAYLOAD=100 ~/tx_capture.sh`。
- 送受で ch/帯域がズレると**エラーも出ずに 1 パケットも受からない**。実行後に両機で
  `iw dev <if> info | grep channel` の `width` と `center1` が一致しているか必ず確認する。

### ⚠️ 電波法上の扱い（この設定は免許が要る）

中心 5795 MHz（UNII-3）は**日本では Wi-Fi 用の割り当てが無く、ETC/DSRC の使用帯域（5.77–5.85 GHz、
路側機の下りは 5.795/5.805/5.815/5.825 GHz）と重なる**。したがって開放空間で使うには次のいずれかが必要:

1. **実験試験局の免許**（総合通信局に申請）… 開放空間で運用する場合は必須
2. **電波暗室・シールドボックス内**での運用
3. 免許不要で済ませるなら **`CH=48 BW=HT40- REG=JP`**（W52、非DFS、技適の範囲内）

`iw reg set US` は**ドライバの送信制限を外すための操作にすぎず、法的根拠にはならない**。
免許またはシールド環境が前提であることを忘れないこと。

### 実験試験局 申請時の諸元（スクリプト既定値との対応）

| 記載欄 | 標準設定での値 | 出どころ |
|---|---|---|
| 無線設備 | Intel WiFi Link 5300（IEEE 802.11n）+ CSI Tool 改造ファーム/ドライバ | — |
| 周波数 | 中心 5795 MHz（157=5785 と 161=5805 のボンディング） | `CH=157` `BW=HT40+` |
| 占有周波数帯幅 | 40 MHz | `BW=HT40+` |
| 変調方式 | OFDM、BPSK〜64QAM（MCS0–7、1ストリーム） | `MCS` |
| 空中線電力 | 15 dBm ≒ 31.6 mW（引数で可変。カード EEPROM 上限まで） | `TXPOW=1500` |
| 空中線 | ノート内蔵アンテナ 2〜3 本（利得は実測/カタログ値） | [SETUP_PC456_JA.md](SETUP_PC456_JA.md) §5 |
| 通信の相手方 | 自局の受信設備（片方向の一斉送信） | injection 方式 |

- **RX 側は免許不要。** monitor モードで受信しかせず、送信設備を含まないため無線局に当たらない。
  スクリプトが `service network-manager stop` で送信の可能性を断っていることが担保。
  → **申請は TX 機のみ**で行う。
- **電波の型式の記号**（`40M0X7W` 等）は分類で決まるため、管轄の総合通信局に照会して確定させること。
- 空中線電力は「`iw set txpower` の設定値」ではなく**空中線端の実際の出力**を記載する必要がある。
  5300 は EEPROM 上限で頭打ちになるので、申請前に実測するか上限値で申請するのが無難。

### トラブル

- `iw set channel 157 HT40+` が `command failed` → 古い regdb が UNII-3 未対応の可能性。regdb 更新か `CH=48` に退避。
- `iw reg set` 直後に `set channel` が走ると**無言で失敗**する（CRDA 反映待ち）。スクリプトは `sleep 3` を挟んである。
- 5300 のハード上限は **ch165 = 5825 MHz**（6 GHz 非対応）。40 MHz の最高が本設定（157+161）。

---

## 5. 解析（MATLAB / Octave）

`linux-80211n-csitool-supplementary/matlab/` を使う。

```matlab
csi_trace = read_bf_file('csi.dat');     % 記録ファイルを読み込み
csi_entry = csi_trace{1};                % 1パケット目
csi = get_scaled_csi(csi_entry);         % [Ntx × Nrx × 30サブキャリア] の複素行列
% 振幅: abs(csi), 位相: angle(csi)
```

---

## 5.5 オフライン運用のための事前準備（要ネット作業を先に済ませる）

> ⚠️ **ファームウェアは全カーネル共通（`/lib/firmware/`）。** CSI ファームに差し替えると
> どのカーネルで起動しても通常 WiFi が使えなくなる（CSI ファームは AP 接続が不安定なため）。
> よって「ネットが要る作業（apt / git / ビルド）」は**標準ファーム・通常カーネル・WiFi 接続中に
> 全部済ませて**から、最後に CSI ファームへ切り替えるのが鉄則。

各ラップトップで、WiFi が使えるうちに以下を実行（両機とも同一でOK＝どちらも TX/RX 兼用にできる）:

```bash
# Part 1: パッケージ（要ネット）
sudo apt-get update
sudo apt-get install -y build-essential libncurses5-dev git-core libpcap-dev octave

# Part 2: リポジトリ（要ネット）
cd ~
git clone https://github.com/mendelas/linux-80211n-csitool.git
git clone https://github.com/dhalperi/linux-80211n-csitool-supplementary.git
git clone https://github.com/dhalperi/lorcon-old.git

# Part 3: ビルド（ネット不要、今のうちに）
cd ~/linux-80211n-csitool && cp /boot/config-$(uname -r) .config
# ★ 2-2 と同じ debugfs 設定を必ず入れる（忘れると monitor_tx_rate が無く injection 不可）
scripts/config --enable DEBUG_FS
scripts/config --enable MAC80211_DEBUGFS
scripts/config --enable IWLWIFI_DEBUG
scripts/config --enable IWLWIFI_DEBUGFS
yes '' | make oldconfig
make -j$(nproc) && sudo make modules_install && sudo make install   # 3.5.7 カーネル
make -C ~/linux-80211n-csitool-supplementary/netlink                # log_to_file
cd ~/lorcon-old && ./configure && make && sudo make install && sudo ldconfig   # LORCON
cd ~/linux-80211n-csitool-supplementary/injection && make           # random_packets

# Part 4: CSI ファームを置くだけ（まだ有効化しない＝WiFi は維持）
sudo cp ~/linux-80211n-csitool-supplementary/firmware/iwlwifi-5000-2.ucode.sigcomm2010 /lib/firmware/
```

**全準備が終わってから** CSI モードへ切替（以降ネット不要）:
```bash
# ★ ドライバは API max=5 なので iwlwifi-5000-5.ucode を最優先で読む。
#   標準の -5/-3/-1 等が残っていると CSI(-2) が読まれず、受信できても csi.dat が 0 になる。
#   → CSI の -2 だけ残し、他の .ucode は全部退避する。
sudo rm -f /lib/firmware/iwlwifi-5000-2.ucode
for f in /lib/firmware/iwlwifi-5000-*.ucode; do sudo mv -f "$f" "$f.standard"; done
sudo ln -sf iwlwifi-5000-2.ucode.sigcomm2010 /lib/firmware/iwlwifi-5000-2.ucode
ls -l /lib/firmware/iwlwifi-5000-*.ucode   # 残る .ucode は -2(CSIリンク) だけ
sudo reboot    # → GRUB で Linux 3.5.7+
```

**標準ファームに戻して WiFi を復活**させたいとき（ネットが再度必要になったら）:
```bash
sudo rm -f /lib/firmware/iwlwifi-5000-2.ucode
for f in /lib/firmware/iwlwifi-5000-*.ucode.orig; do sudo mv -f "$f" "${f%.orig}"; done
# → 3.13 など通常カーネルで起動すれば WiFi が戻る
```

---

## 6. トラブルシューティング早見表

| 症状 | 原因 / 対処 |
|---|---|
| `iwlsifi/... No such file` | コマンドの綴りミス（`iwlwifi` が正しい） |
| `has no member 'channel'` | カーネルが新しすぎ（3.8+）。3.5.7 をビルドして起動 |
| `has no member 'antenna'` | カーネルが古すぎ（3.4）。3.5.7 をビルドして起動 |
| `mkdir cannot create '/lib/modules/...' permission denied` | `sudo make modules_install` で実行 |
| `modinfo` に `connector_log` が無い | 3.5.7+ 以外で起動している。GRUB で選び直す |
| `auth_failures` でアソシエーション失敗 | CSI ファームの既知問題。モニターモード(4-B)へ |
| 受信(tcpdump)はできるのに `csi.dat` が **0 バイト**（その1） | **ドライバが標準ファームを読んでいる**。API max=5 なので `iwlwifi-5000-5.ucode`(標準)が残っていると CSI(-2) が使われない。`-2` 以外の `*.ucode` を全部 `.standard` 等に退避し、iwlwifi 再ロード。`dmesg | grep -i ucode` で `-2` を読んでいるか確認 |
| 受信(tcpdump)はできるのに `csi.dat` が **0 バイト**（その2） | **connector ID 不一致**（フルカーネルビルド時の定番）。カーネル=`CN_NETLINK_USERS(10)+0xf=25`、log_to_file=libcヘッダ(11)+0xf=26 でズレる。`sed -i 's@CN_NETLINK_USERS + 0xf@10 + 0xf@' netlink/iwl_connector.h` して `make -B` で再ビルド。確認: `grep CN_NETLINK_USERS /usr/include/linux/connector.h` が 10 以外なら該当 |
| `Soft blocked: yes`（rfkill） | `sudo rfkill unblock wifi` |
| 通常カーネルでも WiFi が繋がらなくなった | CSI ファームに差し替えた影響（FW は全カーネル共通）。5.5 の「標準ファームに戻す」を実行 |
| LORCON ビルドに WiFi が必要 | ネット作業は標準ファーム時に先に済ませる（5.5 参照）。有線/USBテザリングでも可 |
| `modprobe iwlwifi debug=...` が `invalid argument` | `CONFIG_IWLWIFI_DEBUG` 無効ビルド。`debug` param が無い。kernel を 2-2 の設定で再ビルド、または `setup_inject.sh` から `debug=0x40000` を削除 |
| `monitor_tx_rate` が `find /sys` で出ない | `CONFIG_IWLWIFI_DEBUGFS` 無効ビルド。2-2 の設定（DEBUG_FS/MAC80211_DEBUGFS/IWLWIFI_DEBUG/IWLWIFI_DEBUGFS=y）で**再ビルド必須**（injection の送信レート固定に必要） |
| `tee \`find /sys ...\`` が `no such file` | バックチック内の `find` が非 root で debugfs を辿れない。`$(sudo find /sys/kernel/debug -name monitor_tx_rate)` と find にも sudo を付ける |

---

## 付録: 元のカーネルに戻す

GRUB の "Advanced options for Ubuntu" から元のカーネル（3.13 など）を選べばいつでも戻れる。
ビルドした 3.5.7+ を消す場合:
```bash
sudo rm -rf /lib/modules/3.5.7+ /boot/*3.5.7+*
sudo update-grub
```
標準ファームウェアに戻す場合:
```bash
sudo rm /lib/firmware/iwlwifi-5000-2.ucode
for f in /lib/firmware/iwlwifi-5000-*.ucode.orig; do sudo mv "$f" "${f%.orig}"; done
```

---

*このメモは実際のセットアップ作業（4.4 → 3.13 → 3.4.113 → 3.5.7 ビルドへの試行錯誤）の記録に基づく。*
