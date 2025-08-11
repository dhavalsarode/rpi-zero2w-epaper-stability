# Raspberry Pi Zero 2W + E-Paper Stability Guide

> **日本語版**: See [README_ja.md](README_ja.md) for the Japanese documentation.

SPDX-License-Identifier: MIT

## Purpose

This repository provides a comprehensive stability solution for Raspberry Pi Zero 2W systems with E-Paper displays, addressing common issues such as:

* **Prevention of "frequent crashes/unresponsive" problems** with Zero 2W systems
* **Capturing diagnostic evidence** during failures (5-minute interval snapshots aggregated to collection server)
* **Initial setup checklist** for new installations

---

## Summary (Key Findings)

* The primary cause of instability is **Wi-Fi stack power management behavior** (`brcmfmac` driver issues: `rxctl timeout` / `ASSOCLIST failed, err=-110` leading to communication loss and system freezing).
  → **Disabling NetworkManager Wi-Fi power save** and **forcing it OFF at boot** dramatically **improves stability** (verified with multiple test nodes).

* **Color E-Paper HATs** introduce additional instability through peak current draw and noise during rendering.
  → **Wi-Fi power save OFF remains the highest priority**. Power supply quality (5V/2.5A+, short thick cables, separate power rails for E-Paper if needed) is secondary.

* **5-minute interval status log collection** with **server storage** enables easy post-incident analysis.

---

## Terminology

* **Collection Server** … `<collector_host>` (IP: `<collector_ip>`)
* **Zero** … Target devices (e.g., `<zero_host_1>`, `<zero_host_2>`, `<zero_host_3>`)
* **NICK** … Device identification nickname (e.g., `<node_id_1>`, `<node_id_2>`, `<node_id_3>`)

> Each procedure below clearly indicates **which device to execute commands on**.

---

## 1) Initial Setup (New Installation)

### 1.1 SSH Keys (Register Public Key on Collection Server)

* **Execute on: Zero (each device)**

```bash
# Example: Using existing keys
# Ensure ~/.ssh/id_ed25519 (private) and ~/.ssh/id_ed25519.pub (public) exist

# Register public key on collection server (will prompt "yes" on first connect)
ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@<collector_ip>
```

> Note: Configure `~/.ssh/config` on each Zero with `Host <collector_host> / HostName <collector_ip> / IdentityFile` for easier management.

---

### 1.2 **Wi-Fi Power Save OFF (CRITICAL)**

* **Execute on: Zero (each device)**

NetworkManager global configuration:

```bash
sudo tee /etc/NetworkManager/conf.d/10-wifi-tweaks.conf >/dev/null <<'EOC'
[connection]
wifi.powersave=2
[device]
wifi.scan-rand-mac-address=no
EOC

sudo systemctl restart NetworkManager
```

Force OFF at boot (using absolute paths to avoid PATH issues):

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

Verification:

```bash
/usr/sbin/iw dev wlan0 get power_save   # -> Power save: off
```

> This alone **significantly reduces communication failures and system freezing**.

---

### 1.3 "Self-Recovery" Script (Optional but Recommended)

Automatically attempts recovery when Wi-Fi becomes unresponsive.

* **Execute on: Zero (each device, root privileges)**

```bash
# /usr/local/sbin/wifi-recover.sh
sudo tee /usr/local/sbin/wifi-recover.sh >/dev/null <<'SH'
#!/bin/bash
set -Eeuo pipefail
log(){ echo "[$(date '+%F %T')] wifi-recover: $*"; }
DEV=${1:-wlan0}

CONN=$(/usr/bin/nmcli -t -f NAME,TYPE c show | /usr/bin/awk -F: '$2=="wifi"{print $1;exit}')
ST=$(/usr/bin/nmcli -t -f DEVICE,STATE,CONNECTION device | /usr/bin/awk -F: -v d="$DEV" '$1==d{print $2}')
log "Starting: DEV=$DEV CONN=${CONN:-<unknown>} state=${ST:-<unknown>}"

if [ -n "${CONN:-}" ]; then
  /usr/bin/nmcli -w 5  c down "$CONN" || true
  /usr/bin/nmcli -w 15 c up   "$CONN"  && { log "Recovery successful (connection restart)"; exit 0; }
fi

/usr/bin/nmcli device disconnect "$DEV" || true
sleep 1
/usr/bin/nmcli device connect "$DEV"   && { log "Recovery successful (device reconnect)"; exit 0; }

/usr/bin/nmcli radio wifi off
sleep 2
/usr/sbin/rfkill unblock wifi || true
/usr/bin/nmcli radio wifi on
sleep 3

/sbin/modprobe -r brcmfmac brcmutil || true
/sbin/modprobe brcmfmac || true
/usr/bin/nmcli device connect "$DEV"   && { log "Recovery successful (driver reload)"; exit 0; }

log "Recovery failed"; exit 1
SH
sudo chmod +x /usr/local/sbin/wifi-recover.sh
```

**Root crontab (every 5 minutes, triggered only when gateway unreachable)**:

```bash
sudo crontab -l 2>/dev/null | grep -q wifi-recover.sh ||   ( sudo crontab -l 2>/dev/null;     echo "*/5 * * * * /bin/sh -lc '(ping -c1 -W2 <gateway_ip> || ping -c1 -W2 <collector_ip>) || /usr/local/sbin/wifi-recover.sh >> /var/log/wifi-recover.log 2>&1'"   ) | sudo crontab -
```

---

## 2) Status Log Collection (5-minute intervals / Server Aggregation)

### 2.1 Snapshot Generation (Zero Side)

* **Execute on: Zero (each device, root privileges)**

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
  echo "--- CPU & Temperature & Voltage ---"
  /usr/bin/vcgencmd measure_temp 2>/dev/null | sed 's/^/temp=/'
  /usr/bin/vcgencmd get_throttled 2>/dev/null | sed 's/^/get_throttled: /' || true
  echo "--- Memory Usage ---"
  /usr/bin/free -h
  echo "--- Load Status ---"
  /usr/bin/uptime
  echo "--- dmesg Tail ---"
  /bin/dmesg | /usr/bin/tail -n 50
  echo "--- journalctl Tail ---"
  /usr/bin/journalctl -n 50 --no-pager || true
} > "$TMP"

# Make readable (<user> can scp)
/bin/mv "$TMP" "$OUT"
/bin/chmod 0644 "$OUT"
SH

sudo chmod +x /usr/local/bin/pre-shutdown-log.sh

# Execute every 5 minutes (root)
sudo crontab -l 2>/dev/null | grep -q pre-shutdown-log.sh ||   ( sudo crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/pre-shutdown-log.sh" ) | sudo crontab -
```

### 2.2 Send to Collection Server (Zero Side, User Crontab)

* **Execute on: Zero (each device, <user> account)**

`~/bin/backup-preshutdown.sh` (configure NICK per device):

```bash
mkdir -p ~/bin ~/.cache

cat > ~/bin/backup-preshutdown.sh <<'SH'
#!/bin/bash
set -Eeuo pipefail

# === Device-specific ===
NICK="CHANGE_ME"        # ← Change to <node_id_1> / <node_id_2> / <node_id_3> etc.

# === Server ===
DST_HOST="<user>@<collector_ip>"
DST_DIR="/home/<user>/data/backup/${NICK}"

# === Retention Policy ===
KEEP=300                # Total files: 300 (>24h)
KEEP_UNCOMPRESSED=12    # Recent 1 hour = 12 files keep as raw logs

SRC="/var/log/pre-shutdown-status.log"
TS=$(date +%Y%m%d_%H%M%S)
DST_FILE="pre-shutdown-status_${TS}.log"

# Create destination directory
/usr/bin/ssh -o IdentitiesOnly=yes "$DST_HOST" "/bin/mkdir -p '$DST_DIR'"

# Transfer
/usr/bin/scp -q "$SRC" "$DST_HOST:$DST_DIR/$DST_FILE"

# Compression (compress old raw logs to .gz)
/usr/bin/ssh -o IdentitiesOnly=yes "$DST_HOST" /bin/bash -lc "
  cd '$DST_DIR' || exit 0
  ls -1t pre-shutdown-status_*.log 2>/dev/null | tail -n +$((KEEP_UNCOMPRESSED+1)) | xargs -r -n1 gzip -9
"

# Cleanup (remove files exceeding KEEP limit: .log / .log.gz combined)
/usr/bin/ssh -o IdentitiesOnly=yes "$DST_HOST" /bin/bash -lc "
  cd '$DST_DIR' || exit 0
  ls -1t pre-shutdown-status_*.log* 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f
"

echo "OK"
SH

chmod +x ~/bin/backup-preshutdown.sh
```

**Configure NICK and test**:

```bash
# Example: for <node_id_1> device:
sed -i 's/^NICK=.*/NICK="<node_id_1>"/'  ~/bin/backup-preshutdown.sh
# For <node_id_2> device:
# sed -i 's/^NICK=.*/NICK="<node_id_2>"/'  ~/bin/backup-preshutdown.sh
# For <node_id_3> device:
# sed -i 's/^NICK=.*/NICK="<node_id_3>"/' ~/bin/backup-preshutdown.sh

# Test transmission
~/bin/backup-preshutdown.sh && echo "manual OK"
```

**User crontab (every 5 minutes)**:

```bash
crontab -l 2>/dev/null | grep -q backup-preshutdown.sh ||   ( crontab -l 2>/dev/null; echo "*/5 * * * * /home/<user>/bin/backup-preshutdown.sh >> /home/<user>/.cache/backup-preshutdown.log 2>&1" ) | crontab -
```

---

## 3) Collection Server Verification Methods

* **Execute on: <collector_host>**

```bash
# Latest files and elapsed time (minutes)
now=$(date +%s)
for d in <node_id_1> <node_id_2> <node_id_3>; do
  f=$(ls -1t /home/<user>/data/backup/$d/pre-shutdown-status_*.log* 2>/dev/null | head -n1)
  [ -n "$f" ] || { echo "== $d == (no files)"; continue; }
  mt=$(stat -c %Y "$f"); age=$(((now-mt)/60))
  printf "== %s == age=%2d min  %s\n" "$d" "$age" "$(basename "$f")"
done
```

* **Check for known Wi-Fi error patterns**:

```bash
# Example: <node_id_2> latest file
F=$(ls -1t /home/<user>/data/backup/<node_id_2>/pre-shutdown-status_*.log* | head -n1)
case "$F" in *.gz) Z=zgrep;  ;; *) Z=grep;  esac
$Z -niE 'brcmfmac|rxctl|ASSOCLIST.*-110|disassoc|deauth' -- "$F"
```

* **Power/Temperature/Throttling**:

```bash
case "$F" in *.gz) Z=zgrep;  ;; *) Z=grep;  esac
$Z -niE 'get_throttled|under-voltage|frequency cap|temp' -- "$F"
```

* **Memory Exhaustion / Storage I/O**:

```bash
$Z -niE 'Out of memory|oom-killer' -- "$F" || true
$Z -niE 'mmc|sdhci|EXT4-fs error|I/O error|Buffer I/O error' -- "$F" || true
```

---

## 4) Troubleshooting Guide

### Common Symptoms → Root Cause Identification

* `brcmf_sdio_bus_rxctl: resumed on timeout` / `BRCMF_C_GET_ASSOCLIST failed, err=-110`
  → **Wi-Fi driver related**. **Power save OFF** and **self-recovery (nmcli/rfkill/driver reload)** resolves this.

* `get_throttled: throttled=0x…` with `0x1` (undervoltage) bit set
  → **Insufficient power supply**. Use 5V/2.5A+, short thick cables, **consider separate power rails for color E-Paper** (shared GND).

* `Out of memory` / `oom-killer`
  → Process leaks/heavy load. Investigate activities around log timestamps.

* `EXT4-fs error` / `I/O error` / `mmc0`
  → SD card degradation or contact issues. Consider card replacement and reducing write frequency.

---

## 5) Reinstallation Checklist (Minimal)

1. **Wi-Fi Power Save OFF (Highest Priority)**
   * Install `10-wifi-tweaks.conf` and `disable-wifi-powersave.service`
   * Verify **off** status with `iw ... get power_save`

2. **Self-Recovery (Optional but Recommended)**
   * `wifi-recover.sh` + root crontab (triggered only on gateway unreachable)

3. **Status Log Collection**
   * `pre-shutdown-log.sh` (root, every 5 minutes)
   * `backup-preshutdown.sh` (user, every 5 minutes, configure NICK)

4. **Power Supply**
   * 5V/2.5A+ (extra margin for color E-Paper)
   * Short, thick cables; consider hub/separate rails (shared GND)

5. **Monitoring (Optional)**
   * External monitoring like Uptime Kuma

> **Step (1) Power Save OFF** alone provides significant benefits. Adding (2)(3) enables **automatic recovery from failures** and **evidence preservation**.

---

## 6) Important Notes

* **nmcli permissions**: Regular users often cannot modify system connections  
  → Run `wifi-recover.sh` via **root cron** for reliability.

* **Missing `/usr/sbin` in PATH** (`iw` command not found)  
  → Use **absolute paths** in systemd ExecStart (examples above are compliant).

* **journald.conf syntax**: Comments on the same line as values cause **parse errors**  
  → Write values only like `SystemMaxUse=50M`. Put comments on **separate lines**.

* **scp destination quoting**: Use `"$DST_HOST:$DST_DIR/$DST_FILE"` format (avoid mixing single quotes `'`).

---

## 7) Appendix: Complete File Set

### 7.1 `/usr/local/sbin/wifi-recover.sh` (Zero, root)

> See section 1.3 above. Content omitted for brevity.

### 7.2 `/usr/local/bin/pre-shutdown-log.sh` (Zero, root)

> See section 2.1 above. Content omitted for brevity.

### 7.3 `~/bin/backup-preshutdown.sh` (Zero, user)

> See section 2.2 above. **Remember to change NICK for each device**.

---

## 8) Conclusion (Analysis Summary)

* **Most effective solution was "Wi-Fi Power Save OFF"**. Logs show dramatic reduction in `brcmfmac` errors and confirmed **sustained online presence**.
* **Color E-Paper** acts as a "destabilizing factor" through power load and noise, but **Wi-Fi power save is the root cause** - address this first.
* If instability persists:

  1. Verify power save OFF thoroughly (reconfirm setup per this README)
  2. Monitor `wifi-recover.sh` logs for recovery success/failure patterns
  3. Check `get_throttled` bits for power supply health
  4. Enhance/isolate power supply if needed (especially for color E-Paper)

---

## Project Structure

This repository contains:

- **`scripts/`**: Core monitoring and recovery scripts
  - `backup-preshutdown.sh`: Log collection and server upload
  - `pre-shutdown-log.sh`: System status snapshot generation  
  - `wifi-recover.sh`: Automated Wi-Fi recovery script
- **`systemd/`**: SystemD service configurations
  - `disable-wifi-powersave.service`: Boot-time Wi-Fi power save disable
- **`nm/`**: NetworkManager configurations
  - `10-wifi-tweaks.conf`: Wi-Fi power management settings
- **`cron/`**: Sample crontab configurations
  - `root-crontab.sample`: Root user scheduled tasks
  - `user-crontab.sample`: Regular user scheduled tasks

---

## Acknowledgments

This README was created and refined with technical assistance and content improvement support from AI tools **Gemini (Google)** and **ChatGPT (OpenAI)**. We appreciate their contributions.