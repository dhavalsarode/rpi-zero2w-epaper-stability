#!/bin/bash
# 低負荷・直前状態記録（読みやすい判定つき）
LOGFILE="/var/log/pre-shutdown-status.log"

interpret_throttled() {
  local raw="$1"                # 例: "throttled=0x50005"
  local hex="${raw#*=0x}"       # 例: "50005"
  # vcgencmdの返り値が空なら「不明」
  if [[ -z "$hex" || "$raw" != throttled=* ]]; then
    echo "電圧/温度の状態: 取得できませんでした（vcgencmd未対応/権限不足の可能性）"
    return
  fi
  # 16進→数値
  local v=$((16#$hex))

  local msgs_now=()
  local msgs_hist=()

  # 現在の状態（下位ビット）
  (( v & 0x1 ))   && msgs_now+=("電圧不足（現在）")
  (( v & 0x2 ))   && msgs_now+=("CPU周波数制限：温度/電圧要因（現在）")
  (( v & 0x4 ))   && msgs_now+=("温度制限：80℃以上（現在）")

  # 過去の履歴（上位ビット 16–18）
  (( v & 0x10000 )) && msgs_hist+=("電圧不足（過去に発生）")
  (( v & 0x20000 )) && msgs_hist+=("CPU周波数制限（過去に発生）")
  (( v & 0x40000 )) && msgs_hist+=("温度制限：80℃以上（過去に発生）")

  # 出力整形
  echo "get_throttled: ${raw}"
  if [[ ${#msgs_now[@]} -eq 0 ]]; then
    echo "現在の状態: 問題なし"
  else
    echo "現在の状態: ${msgs_now[*]}"
  fi
  if [[ ${#msgs_hist[@]} -eq 0 ]]; then
    echo "過去の履歴: なし"
  else
    echo "過去の履歴: ${msgs_hist[*]}"
  fi

  # 重要な判断ヒント
  if (( v & 0x1 )) || (( v & 0x10000 )); then
    echo "📌 対策ヒント: 電源品質を確認（ACアダプタ/USBケーブルの交換や短尺化、電源容量の見直し）。"
  fi
  if (( v & 0x4 )) || (( v & 0x40000 )); then
    echo "📌 対策ヒント: 冷却改善（ヒートシンク/ファン、筐体内エアフロー、周囲温度の低減）。"
  fi
}

{
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') ====="
  echo "--- CPU & 温度 & 電圧 ---"
  # 温度
  if command -v vcgencmd >/dev/null 2>&1; then
    vcgencmd measure_temp 2>/dev/null || echo "温度: 取得不可"
    # 電圧・温度スロットリングの判定
    THROTTLED_RAW="$(vcgencmd get_throttled 2>/dev/null || true)"
    interpret_throttled "$THROTTLED_RAW"
  else
    echo "vcgencmd: コマンドが見つかりません（firmware/権限/環境を確認）"
  fi

  echo "--- メモリ使用量 ---"
  free -h || echo "free コマンド実行不可"

  echo "--- 負荷状況 ---"
  uptime || echo "uptime 実行不可"

  echo "--- dmesg 末尾 ---"
  dmesg | tail -n 20 || echo "dmesg 実行不可"

  echo "--- journalctl 末尾 ---"
  journalctl -n 20 --no-pager || echo "journalctl 実行不可"
  echo
} >> "$LOGFILE"
# 例: /usr/local/bin/pre-shutdown-log.sh の最後に追記
chown <user>:<user> /var/log/pre-shutdown-status.log 2>/dev/null || true
chmod 0644        /var/log/pre-shutdown-status.log 2>/dev/null || true
