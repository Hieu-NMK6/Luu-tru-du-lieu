#!/usr/bin/env bash
# Failover: nạp bản dump mới nhất trong siteB/db-backup vào postgres-b rồi khởi động lại mlflow-b.
# GHI ĐÈ toàn bộ db mlflow trên postgres-b (dump có --clean). Dùng: bash scripts/restore_db.sh [tên-file.sql.gz]
set -euo pipefail
source "$(dirname "$0")/lib.sh"

mc ready siteB >/dev/null || die "siteB chưa sẵn sàng (alias tạo bởi 'make setup')"
name="${1:-$(mc ls siteB/db-backup | awk '{print $NF}' | grep '\.sql\.gz$' | sort | tail -1)}"
[[ -n "$name" ]] || die "siteB/db-backup chưa có bản backup nào"
compose exec -T postgres-b pg_isready -U mlflow -d mlflow >/dev/null || die "postgres-b chưa chạy — 'make dr-up' trước"

log "Restore siteB/db-backup/$name -> postgres-b"
mc cat "siteB/db-backup/$name" \
  | compose exec -T postgres-b sh -c 'gunzip | psql -q -U mlflow -d mlflow -v ON_ERROR_STOP=1' >/dev/null
compose restart mlflow-b >/dev/null
ok "Đã restore $name; mlflow-b đã khởi động lại (http://localhost:5100)"
