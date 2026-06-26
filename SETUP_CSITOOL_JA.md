# Intel 5300 CSI Tool セットアップ手順（Ubuntu 14.04）

Linux 802.11n CSI Tool（Halperin et al., University of Washington）を、
**Intel 5300 NIC を積んだ古いノート PC**（例: HP ProBook 6570b）で
動かすための実践メモ。ツール本体は **無改変** で使う前提。

> 対象リポジトリ: このリポジトリ（= Linux 3.5.7 カーネルソース + CSI 対応 iwlwifi ドライバ）
> 別途必要: [linux-80211n-csitool-supplementary](https://github.com/dhalperi/linux-80211n-csitool-supplementary)（ファームウェア・記録/解析ツール）

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
yes '' | make oldconfig          # 質問はすべてデフォルトで自動回答

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

### 4-B. モニターモード受信（2台構成・推奨）

アソシエーション問題を完全に回避できる、CSI 収集の正攻法。**送信機（別 PC / AP / injection 用カード）が必要**。

```
[送信機] ──── 802.11n HT パケット ───▶ [5300ノートPC(モニターモード)]
                                          受信 CSI を log_to_file で記録
```

**受信側（5300 ノート PC）:**
```bash
sudo modprobe -r iwlwifi mac80211 cfg80211
sudo modprobe iwlwifi connector_log=0x1
# NetworkManager が干渉する場合は: sudo service network-manager stop
sudo ip link set wlan1 down
sudo iw dev wlan1 set monitor none
sudo ip link set wlan1 up
sudo iw dev wlan1 set channel 64 HT20      # 送信側とチャンネル/帯域を合わせる
sudo ~/linux-80211n-csitool-supplementary/netlink/log_to_file ~/csi.dat
```

**送信側（もう 1 台）:**
- その PC も **Intel 5300** なら、supplementary の injection ツールでクリーンに送信:
  ```bash
  sudo ~/linux-80211n-csitool-supplementary/injection/setup_inject.sh wlan1 64 HT20
  sudo ~/linux-80211n-csitool-supplementary/injection/random_packets 100000 100 1 ff:ff:ff:ff:ff:ff
  ```
- 5300 でない普通の PC でも、同一チャンネルで HT トラフィックを出せれば受信側で CSI は取れる
  （例: 送信側と受信側を同じ AP に繋いで iperf/ping）。
  ただし受信側 5300 のアソシエーション問題があるため、**injection（送信側 5300）構成が最も確実**。

詳細は supplementary リポジトリの `injection/` 内 README を参照。

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

## 6. トラブルシューティング早見表

| 症状 | 原因 / 対処 |
|---|---|
| `iwlsifi/... No such file` | コマンドの綴りミス（`iwlwifi` が正しい） |
| `has no member 'channel'` | カーネルが新しすぎ（3.8+）。3.5.7 をビルドして起動 |
| `has no member 'antenna'` | カーネルが古すぎ（3.4）。3.5.7 をビルドして起動 |
| `mkdir cannot create '/lib/modules/...' permission denied` | `sudo make modules_install` で実行 |
| `modinfo` に `connector_log` が無い | 3.5.7+ 以外で起動している。GRUB で選び直す |
| `auth_failures` でアソシエーション失敗 | CSI ファームの既知問題。モニターモード(4-B)へ |
| `Soft blocked: yes`（rfkill） | `sudo rfkill unblock wifi` |

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
