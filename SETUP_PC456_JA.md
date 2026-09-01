# PC4/5/6/7 セットアップ記録（NIC 換装前まで）

*記録日: 2026-08-11 / PC7 追記: 2026-09-02*

Intel 5300 への **NIC 換装前**に完了させた作業と、**換装後に残っている作業**の記録。
PC1/2/3 は以前セットアップ済み。**PC4/5/6** に続き、**PC7**（PC4/5/6 と同一機種・同一 Ubuntu 14.04）を追加。
いずれも TX/RX 兼用構成。**PC7 は multi-RX 実験の RX2（`192.168.100.14`）として組み込む**。

> 基本手順は [SETUP_CSITOOL_JA.md](SETUP_CSITOOL_JA.md) を参照。
> multi-RX 実験の運用手順は fork 側の `multi-rx/README.md` が正。
> このファイルは「各機で実際に何をどこまでやったか」の進捗記録＋本家手順への追記事項。

---

## 方針

- **3 台とも同一構成**（どれでも TX にも RX にもなれる）。
- **ネットが要る作業は 5300 換装前に全部済ませる**。CSI ファームに切り替えると
  WiFi が実質使えなくなるため（[SETUP_CSITOOL_JA.md](SETUP_CSITOOL_JA.md) §5.5 の鉄則）。
- 5300 が刺さっていなくても、**実機確認以外はすべて実施可能**。カーネルビルド・
  インストール・起動確認・ツールビルドまで換装前に完了させた。

---

## 1. 換装前に完了した作業

### 1-1. パッケージとリポジトリ【要ネット】

```bash
sudo apt-get update
sudo apt-get install -y build-essential libncurses5-dev git-core libpcap-dev octave
cd ~
git clone https://github.com/mendelas/linux-80211n-csitool.git
git clone https://github.com/mendelas/linux-80211n-csitool-supplementary.git   # ★fork。upstream には multi-rx が無い
git clone https://github.com/dhalperi/lorcon-old.git
wget https://raw.githubusercontent.com/mendelas/linux-80211n-csitool/csitool-stable/csi-scripts/tx_capture.sh -O ~/tx_capture.sh
wget https://raw.githubusercontent.com/mendelas/linux-80211n-csitool/csitool-stable/csi-scripts/rx_capture.sh -O ~/rx_capture.sh
chmod +x ~/tx_capture.sh ~/rx_capture.sh
```

### 1-2. カーネル 3.5.7 ビルド＋インストール

**★ debugfs 4 項目を必ず有効化**（忘れると `monitor_tx_rate` が生成されず injection 不可 →
再ビルド 1 時間コース。TX 機に必須なので全機で有効化しておく）。

```bash
cd ~/linux-80211n-csitool
cp /boot/config-$(uname -r) .config
scripts/config --enable DEBUG_FS
scripts/config --enable MAC80211_DEBUGFS
scripts/config --enable IWLWIFI_DEBUG
scripts/config --enable IWLWIFI_DEBUGFS
yes '' | make oldconfig
grep -E 'CONFIG_DEBUG_FS=|CONFIG_MAC80211_DEBUGFS=|CONFIG_IWLWIFI_DEBUG=|CONFIG_IWLWIFI_DEBUGFS=' .config  # 4つとも =y
make -j$(nproc)
sudo make modules_install
sudo make install
```

### 1-3. ツール類のビルド

```bash
# connector ID をカーネル(10+0xf=25)に合わせる。忘れると csi.dat が 0 バイトになる
sed -i 's@CN_NETLINK_USERS + 0xf@10 + 0xf@' ~/linux-80211n-csitool-supplementary/netlink/iwl_connector.h
make -C ~/linux-80211n-csitool-supplementary/netlink        # log_to_file
cd ~/lorcon-old && ./configure && make && sudo make install && sudo ldconfig
cd ~/linux-80211n-csitool-supplementary/injection && make   # random_packets

# ★ multi-RX 運用に必須（fork にしか無い）。RX 機はこれが無いと制御PCへ流せない
make -C ~/linux-80211n-csitool-supplementary/multi-rx csi_stream
cp ~/linux-80211n-csitool-supplementary/multi-rx/rx_setup.sh ~/ && chmod +x ~/rx_setup.sh
cp ~/linux-80211n-csitool-supplementary/multi-rx/tx_setup.sh ~/ && chmod +x ~/tx_setup.sh
```

### 1-4. CSI ファームウェアの「配置のみ」

```bash
sudo cp ~/linux-80211n-csitool-supplementary/firmware/iwlwifi-5000-2.ucode.sigcomm2010 /lib/firmware/
```

**切替（`-2` 以外の退避 + symlink）は実施していない。→ 換装後に判断する（§3 参照）。**

### 1-5. GRUB のデフォルトを 3.5.7+ に固定

毎回手動で選ぶのは事故のもと（デフォルト起動すると `connector_log` が無い／CSI が 0 バイト）。

```bash
grep -E "menuentry '|submenu '" /boot/grub/grub.cfg | cut -d"'" -f2   # 正確なエントリ名を確認
sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
sudo update-grub
sudo grub-set-default "Advanced options for Ubuntu>Ubuntu, with Linux 3.5.7+"
```

- **番号指定（`"1>2"` 等）は使わない**こと。カーネル更新でメニュー順が変わり別カーネルが
  デフォルトになる事故が起きる。名前指定なら並びが変わっても 3.5.7+ を追い続ける。
- 3.13 等は GRUB メニューに残るので、標準ファームに戻してネット作業したい時は手動選択で戻れる
  （その後も次回起動は 3.5.7+ のまま）。

### 1-6. 蓋を閉じてもサスペンドしない設定

長時間キャプチャ中のサスペンド防止。**2 箇所**設定する（GUI セッション用と logind 用）。

```bash
# デスクトップ側（sudo を付けない = root の設定になってしまい効かないため）
gsettings set org.gnome.settings-daemon.plugins.power lid-close-ac-action nothing
gsettings set org.gnome.settings-daemon.plugins.power lid-close-battery-action nothing
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type nothing
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type nothing

# logind 側（ログイン画面のまま／SSH のみ運用時の保険）
sudo sed -i 's/^#\?HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
grep HandleLidSwitch /etc/systemd/logind.conf     # → HandleLidSwitch=ignore
sudo restart systemd-logind                        # 14.04 は upstart
```

確認: 母艦から `ping` を流したまま蓋を閉じて 1〜2 分放置し、途切れなければ OK。

> 実験中は AC 電源接続を推奨（バッテリー低下時の緊急サスペンドは上記とは別系統）。
> 計測条件を揃えるため、**全機で蓋の開閉状態は統一**する（アンテナが液晶ベゼル内にあるため）。

### 1-7. SSH サーバ ＋ NOPASSWD sudo ＋ 固定IP

CSI ファーム化後も**有線 Ethernet は生きる**ので、csi.dat 回収と TX/RX 同時操作は SSH で行う。

```bash
sudo apt-get install -y openssh-server

# ★ NOPASSWD sudo は multi-RX 運用に必須。
#   制御PC からの ssh には tty が無く、sudo のパスワードを入力できないため
#   （rx_setup.sh / tx_setup.sh / csi_stream はいずれも sudo で動く）。
echo "kota ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/csi && sudo chmod 440 /etc/sudoers.d/csi
```

**固定IP**（`/etc/network/interfaces`）。ハブに DHCP が無いので手動設定する。
制御PC は Pull 方式なので相手の IP を知る必要が無く、固定が要るのは RX/TX 側だけ:

| 機 | 役割 | IP |
|---|---|---|
| 制御PC | 指揮・時刻付与・統合 | 192.168.100.10（同一サブネットなら可変） |
| RX0 | 受信 | 192.168.100.11 |
| RX1 | 受信 | 192.168.100.12 |
| TX | 注入 | 192.168.100.13 |
| **PC7 = RX2** | 受信 | **192.168.100.14** |

設定後、制御PC から鍵を配る:
```bash
ssh-copy-id kota@192.168.100.14
ssh kota@192.168.100.14 "echo ok: \$(hostname)"
```

### 1-8. 解析環境の確認

```bash
octave --eval "addpath('~/linux-80211n-csitool-supplementary/matlab'); which read_bf_file"
```

---

## 2. 換装前 完了チェック（各機で確認）

```bash
uname -r                                            # → 3.5.7+（GRUB 固定が効いているか）
modinfo iwlwifi | grep -i connector                 # → connector_log（カード無しでも確認可）
ls ~/linux-80211n-csitool-supplementary/netlink/log_to_file
ls ~/linux-80211n-csitool-supplementary/injection/random_packets
ls ~/linux-80211n-csitool-supplementary/multi-rx/csi_stream   # multi-RX に必須
ls -l /lib/firmware/iwlwifi-5000-2.ucode.sigcomm2010
ls ~/tx_capture.sh ~/rx_capture.sh ~/rx_setup.sh ~/tx_setup.sh
service ssh status
sudo -n true && echo "NOPASSWD sudo ok"                       # ssh 越しの sudo に必須
git -C ~/linux-80211n-csitool-supplementary remote -v          # → mendelas（upstream だと multi-rx が無い）
```

| 項目 | PC4 | PC5 | PC6 | PC7 |
|---|---|---|---|---|
| パッケージ / clone (1-1) | ☐ | ☐ | ☐ | ☐ |
| **clone 元が mendelas fork** | ☐ | ☐ | ☐ | ☐ |
| カーネル 3.5.7 ビルド (1-2) | ☐ | ☐ | ☐ | ☐ |
| debugfs 4 項目 =y | ☐ | ☐ | ☐ | ☐ |
| ツールビルド (1-3) | ☐ | ☐ | ☐ | ☐ |
| **csi_stream ビルド (1-3)** | ☐ | ☐ | ☐ | ☐ |
| CSI ファーム配置のみ (1-4) | ☐ | ☐ | ☐ | ☐ |
| GRUB 3.5.7+ 固定 (1-5) | ☐ | ☐ | ☐ | ☐ |
| 蓋サスペンド無効 (1-6) | ☐ | ☐ | ☐ | ☐ |
| SSH (1-7) | ☐ | ☐ | ☐ | ☐ |
| **NOPASSWD sudo (1-7)** | ☐ | ☐ | ☐ | ☐ |
| **固定IP (1-7)** | ☐ | ☐ | ☐ | ☐ |
| **NIC 換装** | ☐ | ☐ | ☐ | ☐ |
| 換装後確認 (§4) | ☐ | ☐ | ☐ | ☐ |
| **制御PC に RX2 登録 (§8)** | — | — | — | ☐ |

> **PC7 の時短:** PC4/5/6 と同一機種・同一 14.04 なので、1-2 のカーネルビルド（約1時間）は
> `make_distribution.sh` で PC4 の成果物を移植すれば 5〜10 分で済む。
> ```bash
> ssh pc4 'cd ~/linux-80211n-csitool && ./make_distribution.sh'
> scp pc4:/tmp/kernel-dist-3.5.7+.tgz ~/ && tar xzf ~/kernel-dist-3.5.7+.tgz
> cd kernel-dist-3.5.7+ && ./install_distribution.sh
> grep -E 'CONFIG_DEBUG_FS=|CONFIG_MAC80211_DEBUGFS=|CONFIG_IWLWIFI_DEBUG=|CONFIG_IWLWIFI_DEBUGFS=' /boot/config-3.5.7+
> ```
> 最後の grep が 4 つとも `=y` でなければ移植を捨てて 1-2 を実行すること。
> `install_distribution.sh` は `update-grub` までやるが、**1-5 のデフォルト固定は別途必要**。

---

## 3. 保留した判断：ファームウェア切替のタイミング

**換装後に判断する**ことにした。判断基準は以下。

```bash
lspci | grep -i network
```

- 現行チップが **Intel 5000 系（5100/5300/5350）以外**（Broadcom / Realtek / Atheros / 別世代 Intel 等）
  → `iwlwifi-5000-*.ucode` は現行 WiFi と無関係なので、**切替を先に実施しても WiFi は死なない**。
- 現行チップが **Intel 5000 系** → 切替すると即座に WiFi が使えなくなるので、
  ネット作業がすべて終わってから実施する。

切替コマンド（換装後に実施）:

```bash
# ドライバは API max=5 なので iwlwifi-5000-5.ucode を最優先で読む。
# 標準の -5/-3/-1 が残っていると CSI(-2) が読まれず、受信できても csi.dat が 0 になる。
# → CSI の -2 だけ残し、他は全部退避する。
sudo rm -f /lib/firmware/iwlwifi-5000-2.ucode
for f in /lib/firmware/iwlwifi-5000-*.ucode; do sudo mv -f "$f" "$f.standard"; done
sudo ln -sf iwlwifi-5000-2.ucode.sigcomm2010 /lib/firmware/iwlwifi-5000-2.ucode
ls -l /lib/firmware/iwlwifi-5000-*.ucode   # 残る .ucode は -2（CSI リンク）だけ
```

---

## 4. 換装後に残っている作業（1 台あたり約 5 分）

1. `lspci | grep -i network` → **"Intel ... WiFi Link 5300"** を確認
2. §3 の基準でファーム切替を判断・実施 → `sudo reboot`（GRUB 固定済みなので 3.5.7+ で起動）
3. `iwconfig` でインターフェース名を確認
   → 14.04 の udev 永続ルールにより、**新カードは `wlan1` になる想定**（旧カードの MAC が `wlan0` を占有）。
   スクリプトは `iw dev` の先頭を自動検出するので名前に依らず動くが、無線 IF が複数
   見えていると意図しない方を掴む。その場合は `IF=wlan1 ~/tx_capture.sh` と明示する。
   `wlan0` に戻したい場合は `/etc/udev/rules.d/70-persistent-net.rules` から旧カードの行を削除して再起動。
4. `sudo modprobe iwlwifi && dmesg | grep -i ucode` → **`-2` (sigcomm2010)** を読んでいること
5. `sudo find /sys/kernel/debug -name monitor_tx_rate` → パスが出ること（TX に必須）
6. 2 台揃ったら疎通テスト:
   RX 機 `~/rx_capture.sh` 起動 → TX 機 `sudo ./random_packets 10 100 1`
   → `ls -l` で csi ファイルが 0 バイトでなければ成功

---

## 5. 物理換装時の注意（事前確認事項）

- **BIOS ホワイトリスト**: HP ProBook 系は BIOS に WiFi カードのホワイトリストがあり、
  リスト外の 5300 を挿すと `104-Unsupported wireless network device detected` で
  起動を拒否されることがある。**HP 純正部品番号（例: 482260-001）**の 5300 を用意するのが確実。
- **アンテナ本数**: Intel 5300 は**アンテナ端子が 3 つ**。ノート内蔵アンテナは通常 2 本（MAIN/AUX）。
  2 本でも動作するが、**3x3 で取りたいなら 3 本目を別途調達**。
  どの端子（1/2/3）に何本つないだかは解析時に必要なので**機体ごとに記録を残す**こと。
- 精密ドライバ・静電対策、機種ごとの分解手順（アクセスパネル下かキーボード下か）を事前確認。

---

## 6. キャプチャスクリプトのデフォルト設定に関する注意

[csi-scripts/tx_capture.sh](csi-scripts/tx_capture.sh) / [csi-scripts/rx_capture.sh](csi-scripts/rx_capture.sh)
の現在のデフォルト（= **標準設定**）は:

| 項目 | 値 | 備考 |
|---|---|---|
| CH | 157（5785 MHz） | 制御チャンネル |
| BW | HT40+（拡張ch=161、**中心 5795 MHz**） | ★`HT40` 単体は `iw` がエラーにする |
| 規制ドメイン | `iw reg set US` | UNII-3 を開放するため |
| RATE | 自動計算（MCS1/HT40 → 0x4901） | `MCS` から算出。直接指定も可 |
| 送信電力 | 15 dBm（1500 mBm） | 第1引数で変更可 |
| IF | 自動検出（`iw dev` の先頭） | `IF=` で上書き可 |

**この設定（中心 5795 MHz / UNII-3）は日本では Wi-Fi 用の割り当てが無く、ETC/DSRC の帯域と重なる。**
運用は **① 実験試験局の免許を取得**（開放空間で使う場合は必須）、または **② 電波暗室・シールドボックス内**
のいずれかに限ること。免許不要で済ませたい場合は環境変数で
**`CH=48 BW=HT40- REG=JP`**（W52、非DFS、技適の範囲内）に退避する。

> `iw reg set US` はドライバの送信制限を外す操作にすぎず、法的根拠にはならない。
> 詳細は [SETUP_CSITOOL_JA.md](SETUP_CSITOOL_JA.md) §4-C（申請時の諸元表も同節）。

送受で ch / 帯域が食い違うと 1 パケットも受からず、原因切り分けで時間を浪費する。
実行後に両機で `iw dev <if> info | grep channel` の `width` と `center1` の一致を必ず確認すること。

---

## 7. トラブル時

[SETUP_CSITOOL_JA.md](SETUP_CSITOOL_JA.md) §6 のトラブルシューティング早見表を参照。
特に頻出:

- **csi.dat が 0 バイト** → ①標準ファームを読んでいる（`-2` 以外を退避したか）
  ②connector ID 不一致（`iwl_connector.h` の sed を当てて `make -B` したか）
- **`monitor_tx_rate` が見つからない** → `CONFIG_IWLWIFI_DEBUGFS` 無効ビルド。カーネル再ビルドが必要
- **`iw set channel` が無言で失敗** → `iw reg set` 直後の CRDA 反映待ち。`sleep` を挟む
- **ssh 越しの sudo で止まる** → NOPASSWD sudo 未設定（§1-7 の `/etc/sudoers.d/csi`）
- **`multi-rx/` が無い** → clone 元が upstream(dhalperi)。fork(mendelas) に切り替える:
  `git remote set-url origin https://github.com/mendelas/linux-80211n-csitool-supplementary.git && git pull`

---

## 8. PC7 を RX2 として制御PCに登録する

`run_experiment.sh` は **RX2 を任意扱い**にしてある（空なら従来どおり 2RX で走る）。
PC7 の換装後確認（§4）まで終わったら、**制御PC 側で 1 行だけ**有効化する:

```bash
# 制御PC: ~/linux-80211n-csitool-supplementary/multi-rx/run_experiment.sh
RX2=kota@192.168.100.14      # 空欄だった行を埋める
```

これだけで以下が自動的に 3RX 構成になる:

- `rx_setup.sh` を RX2 にも送る（ch/BW は RX0/RX1 と同一値が渡る）
- `csi_stream` → `csi_recv 2` で `..._rx2.bin` に記録
- CSI 到達待ちの判定に RX2 を含める（RX2 だけ流れないと WARNING が出る）
- `csi_merge` の入力に `rx2.bin` を追加（`read_merged` の `rx` フィールドが 0/1/2）
- 終了時に RX2 の `csi_stream` も停止

**逆に PC7 を外したい**ときは `RX2=` を空に戻すだけ。ファイル名・merge 引数の手当ては不要。

> 4 台目以降を足す場合は同じ要領で `RX3` を追加する（`csi_recv 3` / `csi_merge` の引数 /
> 待ち判定）。`csi_merge` は `<out> <in0> [in1 ...]` の可変長なので入力追加自体は自由。
