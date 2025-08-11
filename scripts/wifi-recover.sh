#!/bin/bash
# /usr/local/sbin/wifi-recover.sh  (r2)
set -Eeuo pipefail
PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
LANG=C
WAIT_DOWN="${WAIT_DOWN:-5}"
WAIT_UP="${WAIT_UP:-45}"

log(){ echo "[$(date '+%F %T')] wifi-recover: $*"; command -v logger >/dev/null && logger -t wifi-recover -- "$*" || true; }
nm(){ command -v nmcli >/dev/null || { log "nmcli が見つかりません"; exit 1; }; nmcli "$@"; }

detect_wifi_dev(){ nm -t -f DEVICE,TYPE,STATE device | awk -F: '$2=="wifi"{print $1; exit}'; }
DEV="${WIFI_DEV:-$(detect_wifi_dev)}"
device_state(){ nm -t -f DEVICE,TYPE,STATE device | awk -F: -v d="$DEV" '$1==d{print $3; exit}'; }
is_connected(){ [[ "$(device_state)" == "connected" ]]; }

# アクティブ接続名 → 無ければ保存済みWi-Fiプロファイルの先頭を候補に
get_active_conn(){ nm -t -f NAME,UUID,TYPE,DEVICE con show --active | awk -F: -v d="$DEV" '$3=="802-11-wireless" && $4==d{print $1; exit}'; }
get_any_saved_wifi(){ nm -t -f NAME,TYPE con show | awk -F: '$2=="802-11-wireless"{print $1; exit}'; }
CONN="${WIFI_CONN:-$(get_active_conn)}"; [[ -z "${CONN:-}" ]] && CONN="$(get_any_saved_wifi)"

ensure_managed(){
  nm dev set "$DEV" managed yes || true
  rfkill unblock wifi || true
}

up_conn(){
  nm -w "$WAIT_UP" con up id "$CONN"
}

log "開始: DEV=${DEV:-<不明>} CONN=${CONN:-<不明>} state=$(device_state)"

ensure_managed
nm con reload || true

# 1) 接続を落として上げる（接続名を明示）
if [[ -n "${CONN:-}" ]]; then
  nm -w "$WAIT_DOWN" con down id "$CONN" || true
  if up_conn; then
    is_connected && { log "復帰成功（state=$(device_state)）"; exit 0; }
  fi
fi

# 2) ラジオ再投入後に「接続名で」再試行（device connect は使わない）
log "ラジオを OFF→ON"
nm radio wifi off || true
sleep 2
nm radio wifi on || true
ensure_managed
sleep 2
nm dev disconnect "$DEV" || true
sleep 1
if [[ -n "${CONN:-}" ]]; then
  if up_conn; then
    is_connected && { log "復帰成功（state=$(device_state)）"; exit 0; }
  fi
fi

# 3) それでもダメなら brcmfmac を再読み込み → 接続名で up
if lsmod | grep -q '^brcmfmac'; then
  log "brcmfmac ドライバ再読み込み"
  modprobe -r brcmfmac 2>/dev/null || true
  sleep 2
  modprobe brcmfmac 2>/dev/null || true
  sleep 3
  ensure_managed
  nm con reload || true
  if [[ -n "${CONN:-}" ]]; then
    up_conn || true
  fi
fi

# 4) 最終判定
if is_connected; then
  log "復帰成功（state=$(device_state)）"
  exit 0
else
  log "復帰失敗（state=$(device_state)）。手動確認をお願いします。"
  exit 1
fi
