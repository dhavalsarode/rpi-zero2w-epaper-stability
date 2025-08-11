# README — Raspberry Pi Zero 2 W + E-Paper 安定運用ガイド
SPDX-License-Identifier: MIT

## 目的

* **Zero 2 W が “よく落ちる/応答しなくなる” 問題**の再発防止
* 障害発生時に**原因の手がかりを確実に残す**（5分ごとのスナップショットを収集サーバへ集約）
* **再インストール時の初期設定**チェックリスト

---

## 結論（要約）

* 障害の主因は**Wi-Fiスタックの省電力挙動**（`brcmfmac` の `rxctl timeout` / `ASSOCLIST failed, err=-110` 連発 → 通信断・固まり）。
  → **NetworkManager の Wi-Fi 省電力を OFF**、かつ**起動時に強制 OFF**にするだけで **安定性が大きく向上**（`<node_id_1>` / `<node_id_2>` / `<node_id_3>` で実証）。

* **カラー E-Paper HAT**は描画時のピーク電流・ノイズが**追加の不安定化要因**。
  → それでも **Wi-Fi 省電力 OFF が最優先**。次点で**電源品質**（5V/2.5A 以上、短く太いケーブル、必要なら E-Paper 側を別系統に）。

* 5分ごとの**状態ログ収集**＋**サーバ保管**を入れたことで、**後追い調査が容易**に。

---

## 用語

* **収集サーバ** … `<collector_host>`（IP: `<collector_ip>`）
* **Zero** … 収集対象（例：`<zero_host_1>` / `<zero_host_2>` / `<zero_host_3>`）
* **NICK** … 端末識別用ニックネーム（例：`<node_id_1>`, `<node_id_2>`, `<node_id_3>`）

> 以下、**どの端末で実行するか**を各手順の冒頭に明記しています。

---

## 1) 初期セットアップ（新規インストール時）

### 1.1 SSH 鍵（収集サーバ側に公開鍵を登録）

* **実行する端末：Zero（各台）**

```bash
# 例: 既存の鍵を使う場合
# ~/.ssh/id_ed25519（秘密鍵）と ~/.ssh/id_ed25519.pub（公開鍵）があること

# 収集サーバに公開鍵を登録（初回は "yes" を聞かれます）
ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@<collector_ip>
```

> 補足：各 Zero の `~/.ssh/config` を使うなら、`Host <collector_host> / HostName <collector_ip> / IdentityFile` を揃えておくと楽です。

---

### 1.2 **Wi-Fi 省電力 OFF（最重要）**

* **実行する端末：Zero（各台）**

NetworkManager 全体設定：

```bash
sudo tee /etc/NetworkManager/conf.d/10-wifi-tweaks.conf >/dev/null <<'EOC'
[connection]
wifi.powersave=2
[device]
wifi.scan-rand-mac-address=no
EOC

sudo systemctl restart NetworkManager
```

起動時に必ず OFF（PATH 問題回避のため絶対パスで）：

```bash
sudo tee /etc/systemd/system/disable-wifi-powersave.service >/dev/null <<'EOS'
[Unit]
Description=Disable Wi-Fi power save
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/iw dev wlan0 set power_save off

[Install]
WantedBy=multi-user.target
EOS

sudo systemctl daemon-reload
sudo systemctl enable --now disable-wifi-powersave.service
```

確認：

```bash
/usr/sbin/iw dev wlan0 get power_save   # -> Power save: off
```

> これだけで **通信断・固まりの発生頻度が大幅低下**します。

---

### 1.3 「自己回復」スクリプト（任意・推奨）

Wi-Fi が詰まった場合に **自動で復帰を試みる**。

* **実行する端末：Zero（各台・root 権限）**

```bash
# /usr/local/sbin/wifi-recover.sh
sudo tee /usr/local/sbin/wifi-recover.sh >/dev/null <<'SH'
#!/bin/bash
set -Eeuo pipefail
log(){ echo "[$(date '+%F %T')] wifi-recover: $*"; }
DEV=${1:-wlan0}

CONN=$(/usr/bin/nmcli -t -f NAME,TYPE c show | /usr/bin/awk -F: '$2=="wifi"{print $1;exit}')
ST=$(/usr/bin/nmcli -t -f DEVICE,STATE,CONNECTION device | /usr/bin/awk -F: -v d="$DEV" '$1==d{print $2}')
log "開始: DEV=$DEV CONN=${CONN:-<不明>} state=${ST:-<不明>}"

if [ -n "${CONN:-}" ]; then
  /usr/bin/nmcli -w 5  c down "$CONN" || true
  /usr/bin/nmcli -w 15 c up   "$CONN"  && { log "復帰成功（connection restart）"; exit 0; }
fi

/usr/bin/nmcli device disconnect "$DEV" || true
sleep 1
/usr/bin/nmcli device connect "$DEV"   && { log "復帰成功（device reconnect）"; exit 0; }

/usr/bin/nmcli radio wifi off
sleep 2
/usr/sbin/rfkill unblock wifi || true
/usr/bin/nmcli radio wifi on
sleep 3

/sbin/modprobe -r brcmfmac brcmutil || true
/sbin/modprobe brcmfmac || true
/usr/bin/nmcli device connect "$DEV"   && { log "復帰成功（driver reload）"; exit 0; }

log "復帰失敗"; exit 1
SH
sudo chmod +x /usr/local/sbin/wifi-recover.sh
```

**root の crontab（5分おき／GW 不達のときだけ発動）**：

```bash
sudo crontab -l 2>/dev/null | grep -q wifi-recover.sh ||   ( sudo crontab -l 2>/dev/null;     echo "*/5 * * * * /bin/sh -lc '(ping -c1 -W2 <gateway_ip> || ping -c1 -W2 <collector_ip>) || /usr/local/sbin/wifi-recover.sh >> /var/log/wifi-recover.log 2>&1'"   ) | sudo crontab -
```

---

## 2) 状態ログの収集（5分おき／収集サーバへ集約）

### 2.1 スナップショット生成（Zero 側）

* **実行する端末：Zero（各台・root 権限）**

```bash
# /usr/local/bin/pre-shutdown-log.sh
sudo tee /usr/local/bin/pre-shutdown-log.sh >/dev/null <<'SH'
#!/bin/bash
set -Eeuo pipefail
OUT=/var/log/pre-shutdown-status.log
TMP=$(mktemp)

ts() { date '+===== %F %T ====='; }

{
  ts
  echo "--- CPU & 温度 & 電圧 ---"
  /usr/bin/vcgencmd measure_temp 2>/dev/null | sed 's/^/temp=/'
  /usr/bin/vcgencmd get_throttled 2>/dev/null | sed 's/^/get_throttled: /' || true
  echo "--- メモリ使用量 ---"
  /usr/bin/free -h
  echo "--- 負荷状況 ---"
  /usr/bin/uptime
  echo "--- dmesg 末尾 ---"
  /bin/dmesg | /usr/bin/tail -n 50
  echo "--- journalctl 末尾 ---"
  /usr/bin/journalctl -n 50 --no-pager || true
} > "$TMP"

# 読み取り可能に（<user> ユーザが scp できるように）
/bin/mv "$TMP" "$OUT"
/bin/chmod 0644 "$OUT"
SH

sudo chmod +x /usr/local/bin/pre-shutdown-log.sh

# 5分おきに実行（root）
sudo crontab -l 2>/dev/null | grep -q pre-shutdown-log.sh ||   ( sudo crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/pre-shutdown-log.sh" ) | sudo crontab -
```

### 2.2 収集サーバへ送る（Zero 側・ユーザ crontab）

* **実行する端末：Zero（各台・<user> ユーザ）**

`~/bin/backup-preshutdown.sh`（NICK を端末ごとに設定）：

```bash
mkdir -p ~/bin ~/.cache

cat > ~/bin/backup-preshutdown.sh <<'SH'
#!/bin/bash
set -Eeuo pipefail

# === 端末固有 ===
NICK="CHANGE_ME"        # ← <node_id_1> / <node_id_2> / <node_id_3> などに変更

# === サーバ ===
DST_HOST="<user>@<collector_ip>"
DST_DIR="/home/<user>/data/backup/${NICK}"

# === 保持ポリシー ===
KEEP=300                # 総本数：300（>24h）
KEEP_UNCOMPRESSED=12    # 直近 1 時間 = 12 本は生ログのまま

SRC="/var/log/pre-shutdown-status.log"
TS=$(date +%Y%m%d_%H%M%S)
DST_FILE="pre-shutdown-status_${TS}.log"

# 送付先ディレクトリ生成
/usr/bin/ssh -o IdentitiesOnly=yes "$DST_HOST" "/bin/mkdir -p '$DST_DIR'"

# 転送
/usr/bin/scp -q "$SRC" "$DST_HOST:$DST_DIR/$DST_FILE"

# 圧縮（古い生ログを .gz に）
/usr/bin/ssh -o IdentitiesOnly=yes "$DST_HOST" /bin/bash -lc "
  cd '$DST_DIR' || exit 0
  ls -1t pre-shutdown-status_*.log 2>/dev/null | tail -n +$((KEEP_UNCOMPRESSED+1)) | xargs -r -n1 gzip -9
"

# 削除（KEEP を超えたものを掃除： .log / .log.gz 合算）
/usr/bin/ssh -o IdentitiesOnly=yes "$DST_HOST" /bin/bash -lc "
  cd '$DST_DIR' || exit 0
  ls -1t pre-shutdown-status_*.log* 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f
"

echo "OK"
SH

chmod +x ~/bin/backup-preshutdown.sh
```

**NICK を設定**してテスト：

```bash
# 例: <node_id_1> の端末なら：
sed -i 's/^NICK=.*/NICK="<node_id_1>"/'  ~/bin/backup-preshutdown.sh
# <node_id_2> の端末なら：
# sed -i 's/^NICK=.*/NICK="<node_id_2>"/'  ~/bin/backup-preshutdown.sh
# <node_id_3> の端末なら：
# sed -i 's/^NICK=.*/NICK="<node_id_3>"/' ~/bin/backup-preshutdown.sh

# テスト送信
~/bin/backup-preshutdown.sh && echo "manual OK"
```

**ユーザ crontab（5分おき）**：

```bash
crontab -l 2>/dev/null | grep -q backup-preshutdown.sh ||   ( crontab -l 2>/dev/null; echo "*/5 * * * * /home/<user>/bin/backup-preshutdown.sh >> /home/<user>/.cache/backup-preshutdown.log 2>&1" ) | crontab -
```

---

## 3) 収集サーバ側の確認方法

* **実行する端末：<collector_host>**

```bash
# 最新ファイルと経過時間（分）
now=$(date +%s)
for d in <node_id_1> <node_id_2> <node_id_3>; do
  f=$(ls -1t /home/<user>/data/backup/$d/pre-shutdown-status_*.log* 2>/dev/null | head -n1)
  [ -n "$f" ] || { echo "== $d == (no files)"; continue; }
  mt=$(stat -c %Y "$f"); age=$(((now-mt)/60))
  printf "== %s == age=%2d min  %s
" "$d" "$age" "$(basename "$f")"
done
```

* **Wi-Fi 既知のエラーパターンをチェック**：

```bash
# 例: <node_id_2> の最新ファイル
F=$(ls -1t /home/<user>/data/backup/<node_id_2>/pre-shutdown-status_*.log* | head -n1)
case "$F" in *.gz) Z=zgrep;  ;; *) Z=grep;  esac
$Z -niE 'brcmfmac|rxctl|ASSOCLIST.*-110|disassoc|deauth' -- "$F"
```

* **電源/温度/スロットリング**：

```bash
case "$F" in *.gz) Z=zgrep;  ;; *) Z=grep;  esac
$Z -niE 'get_throttled|under-voltage|frequency cap|temp' -- "$F"
```

* **メモリ枯渇 / ストレージ I/O**：

```bash
$Z -niE 'Out of memory|oom-killer' -- "$F" || true
$Z -niE 'mmc|sdhci|EXT4-fs error|I/O error|Buffer I/O error' -- "$F" || true
```

---

## 4) トラブル発生時の見立て

### よくある症状 → 原因の当たり

* `brcmf_sdio_bus_rxctl: resumed on timeout` / `BRCMF_C_GET_ASSOCLIST failed, err=-110`
  → **Wi-Fi ドライバ絡み**。今回、**省電力 OFF** と **自己回復（nmcli/rfkill/driver reload）**で収束。

* `get_throttled: throttled=0x…` に `0x1`（undervoltage）ビットが立つ
  → **電源不足**。5V/2.5A 以上、短い太いケーブル、**カラー E-Paper なら別系統給電も検討**（GND は共通）。

* `Out of memory` / `oom-killer`
  → プロセスリーク/重負荷。ログ時刻前後の動作を洗う。

* `EXT4-fs error` / `I/O error` / `mmc0`
  → SD 劣化や接触。カード交換・書き込み頻度の見直しを。

---

## 5) 再インストール時チェックリスト（最小）

1. **Wi-Fi 省電力 OFF（最優先）**

   * `10-wifi-tweaks.conf` と `disable-wifi-powersave.service` を入れる
   * `iw ... get power_save` で **off** を確認

2. **自己回復（任意・推奨）**

   * `wifi-recover.sh` + root crontab（GW 不達時のみ起動）

3. **状態ログ収集**

   * `pre-shutdown-log.sh`（root, 5分おき）
   * `backup-preshutdown.sh`（ユーザ, 5分おき, NICK 設定）

4. **電源まわり**

   * 5V/2.5A 以上（カラー E-Paper は余裕を）
   * ケーブル短く太く、ハブ/別系統（GND 共通）も検討

5. **監視（任意）**

   * Uptime Kuma など外形監視

> まず **(1) 省電力 OFF** を入れるだけでも効果は大。次に (2)(3) を乗せれば、**詰まりの自動復帰** と **証跡保全**が整います。

---

## 6) 注意メモ

* **nmcli 権限**：一般ユーザは system connection をいじれないことが多い  
  → `wifi-recover.sh` は **root の cron** で回すのが確実。

* **`/usr/sbin` が PATH に無い**（`iw` が見えない）  
  → systemd の ExecStart は **絶対パス**にする（本書の例は対応済み）。

* **journald.conf の書式**：値の行末にコメントを同一行で書くと **parse error**  
  → `SystemMaxUse=50M` のように値だけを記載。コメントは**別行**に書く。

* **scp 先のクォート**：`"$DST_HOST:$DST_DIR/$DST_FILE"` の形にする（余計な単引用 `'` を混ぜない）。

---

## 7) 付録：ファイル一式

### 7.1 `/usr/local/sbin/wifi-recover.sh`（Zero・root）

> 上記 1.3 に掲載のとおり。再掲は省略。

### 7.2 `/usr/local/bin/pre-shutdown-log.sh`（Zero・root）

> 上記 2.1 に掲載のとおり。再掲は省略。

### 7.3 `~/bin/backup-preshutdown.sh`（Zero・ユーザ）

> 上記 2.2 に掲載のとおり。**NICK を端末ごとに変更**して使ってください。

---

## 8) さいごに（今回の考察）

* **最も効いたのは「Wi-Fi 省電力 OFF」**。ログでも `brcmfmac` のエラー頻度が激減し、その後の **オンライン継続**を確認。
* **カラー E-Paper**は電源負荷・ノイズの“悪化要因”として働くが、**根因は Wi-Fi 側の省電力**で、まずそこを潰すのが正解。
* どうしても不安定が再発する場合は、

  1. 省電力 OFF 徹底（本 README の手順通りになっているか再確認）
  2. `wifi-recover.sh` のログで復帰可否を観察
  3. `get_throttled` のビットで電源健全性を確認
  4. 必要なら **給電を強化/分離**（特にカラー E-Paper）

---

## 謝辞 (Acknowledgments)

本READMEの作成・推敲にあたり、生成AIツール **Gemini (Google)** および **ChatGPT (OpenAI)** を活用しました。両ツールの支援に感謝いたします。

