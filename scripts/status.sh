#!/usr/bin/env bash
# Xem nhanh trạng thái replication và backup trên cả hai site (chỉ đọc).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

log "mc admin replicate status siteA"
mc admin replicate status siteA
for s in siteA siteB; do
  log "$s: số object theo bucket"
  for b in raw-data mlflow-artifacts db-backup logs; do
    printf '  %-17s %s object\n' "$b" "$(mc ls -r "$s/$b" 2>/dev/null | wc -l | tr -d ' ')"
  done
  log "$s/db-backup (5 bản mới nhất)"
  mc ls "$s/db-backup" | tail -5
done
