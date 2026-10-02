#!/usr/bin/env bash
# pg_dump postgres-a -> gzip -> siteA/db-backup/mlflow_YYYYmmdd_HHMMSS.sql.gz
# Chạy trong container backup-cron (cron mỗi 5 phút, hoặc `make backup`).
# Cần: PGHOST/PGUSER/PGPASSWORD/PGDATABASE và MC_HOST_siteA (user backup, không phải root).
set -euo pipefail
[[ -f /etc/backup.env ]] && source /etc/backup.env   # crond không truyền env của container

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [backup] $*"; }

name="mlflow_$(date +%Y%m%d_%H%M%S).sql.gz"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

log "pg_dump ${PGDATABASE}@${PGHOST} -> ${name}"
pg_dump --no-owner --clean --if-exists | gzip -9 > "$tmp/$name"
gzip -t "$tmp/$name"
log "Kích thước: $(du -h "$tmp/$name" | cut -f1)"

mc --no-color --quiet cp "$tmp/$name" "siteA/db-backup/$name" >/dev/null
mc --no-color stat "siteA/db-backup/$name" | grep -i encrypt || true
log "OK -> siteA/db-backup/$name"
