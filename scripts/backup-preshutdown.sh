#!/bin/bash
set -Eeuo pipefail
KEEP=300

# --- 固有設定 ---
NICK="<node_id_1>"                         # ← この端末のニックネーム
DST_HOST="<collector_ip>"           # rpi5 のIP（固定）
KEY="$HOME/.ssh/<backup_key>"  # rpi5用の鍵
# ----------------

SRC="/var/log/pre-shutdown-status.log"
DST_DIR="/home/<user>/data/backup/${NICK}"
STAMP="$(date '+%Y%m%d_%H%M%S')"
DST_FILE="pre-shutdown-status_${STAMP}.log"

# 可能なら pigz
COMPRESSOR="gzip -9f"
ssh -i "$KEY" -o IdentitiesOnly=yes "$DST_HOST" 'command -v pigz >/dev/null 2>&1' && COMPRESSOR="pigz -9f"

# 保存先作成（rpi5）
ssh -i "$KEY" -o IdentitiesOnly=yes "$DST_HOST" "mkdir -p \"$DST_DIR\""

# 転送（★余計なクォートなし★）
scp -i "$KEY" -o IdentitiesOnly=yes -q "$SRC" "$DST_HOST:$DST_DIR/$DST_FILE"

# リモート側で整理
ssh -i "$KEY" -o IdentitiesOnly=yes "$DST_HOST" bash -lc "
  set -Eeuo pipefail
  KEEP=300
  KEEP_UNCOMPRESSED=12
  PRUNE_DAYS_GZ=180

  LOGS_ALL=( \$(ls -1t \"$DST_DIR\"/pre-shutdown-status_*.log* 2>/dev/null || true) )
  if [ \${#LOGS_ALL[@]} -gt \$KEEP ]; then
    printf '%s\n' \"\${LOGS_ALL[@]}\" | tail -n +\$(( KEEP + 1 )) | xargs -r rm -f --
  fi

  LOGS_RAW=( \$(ls -1t \"$DST_DIR\"/pre-shutdown-status_*.log 2>/dev/null || true) )
  if [ \${#LOGS_RAW[@]} -gt \$KEEP_UNCOMPRESSED ]; then
    printf '%s\n' \"\${LOGS_RAW[@]}\" | tail -n +\$(( KEEP_UNCOMPRESSED + 1 )) | xargs -r -I{} $COMPRESSOR '{}'
  fi

  find \"$DST_DIR\" -type f -name 'pre-shutdown-status_*.log.gz' -mtime +\$PRUNE_DAYS_GZ -delete
"
echo "OK"
KEEP_UNCOMPRESSED=12
