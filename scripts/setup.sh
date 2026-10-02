#!/usr/bin/env bash
# Cấu hình lưu trữ + sao lưu + bảo mật cho 2 site MinIO. Chạy lại nhiều lần an toàn.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

BUCKETS=(raw-data mlflow-artifacts db-backup logs)

# ---------------------------------------------------------------- 1. alias
log "1. Tạo alias siteA ($SCHEME://localhost:9000) và siteB ($SCHEME://localhost:9100)"
mc alias set siteA $SCHEME://localhost:9000 "$MINIO_A_ROOT_USER" "$MINIO_A_ROOT_PASSWORD" >/dev/null
mc alias set siteB $SCHEME://localhost:9100 "$MINIO_B_ROOT_USER" "$MINIO_B_ROOT_PASSWORD" >/dev/null
for s in siteA siteB; do
  mc ready "$s" >/dev/null || die "$s chưa sẵn sàng (đã 'make up' chưa? TLS: đã tin certs/ca.crt chưa — xem docs/security.md)"
done
ok "Alias siteA, siteB hoạt động"

# ------------------------------------------------------- 2. site replication
# Làm TRƯỚC khi tạo bucket: siteB phải trống khi join; sau đó mọi bucket, cấu hình
# (versioning, object lock, SSE, ILM), IAM user/policy tạo trên siteA đều tự sang siteB.
log "2. Site Replication siteA <-> siteB"
if mc admin replicate info siteA --json | grep -q '"enabled": *true'; then
  ok "Site Replication đã bật từ trước -> bỏ qua"
else
  # Endpoint ngang hàng phải là tên nội bộ (minio-a/minio-b) trên network 'replication',
  # vì 'localhost:9100' bên trong container minio-a không trỏ tới minio-b.
  compose run --rm --no-deps \
    -e "MC_HOST_a=${SCHEME}://${MINIO_A_ROOT_USER}:${MINIO_A_ROOT_PASSWORD}@minio-a:9000" \
    -e "MC_HOST_b=${SCHEME}://${MINIO_B_ROOT_USER}:${MINIO_B_ROOT_PASSWORD}@minio-b:9000" \
    mc --no-color admin replicate add a b --replicate-ilm-expiry
  ok "Đã thêm Site Replication"
fi

# ------------------------------------------------- 3. bucket + versioning + lock
log "3. Bucket, versioning, Object Lock"
for b in raw-data mlflow-artifacts logs; do
  mc mb --ignore-existing "siteA/$b" >/dev/null
  mc version enable "siteA/$b" >/dev/null
  ok "siteA/$b (versioning: bật)"
done

if mc stat "siteA/db-backup" >/dev/null 2>&1; then
  mc retention info --default siteA/db-backup 2>/dev/null | grep -qi compliance \
    || die "siteA/db-backup đã tồn tại nhưng KHÔNG có Object Lock (chỉ bật được lúc tạo bucket) — chạy 'make clean' rồi làm lại"
else
  mc mb --with-lock siteA/db-backup >/dev/null   # --with-lock tự bật versioning
fi
mc retention set --default COMPLIANCE 1d siteA/db-backup >/dev/null
ok "siteA/db-backup (versioning + Object Lock COMPLIANCE 1 ngày)"

# ------------------------------------------------------ 4. mã hóa SSE-S3
log "4. Mã hóa phía server SSE-S3 (KMS tĩnh MINIO_KMS_SECRET_KEY)"
for b in "${BUCKETS[@]}"; do
  mc encrypt set sse-s3 "siteA/$b" >/dev/null
done
ok "SSE-S3 mặc định cho: ${BUCKETS[*]}"

# ------------------------------------------------------------ 5. lifecycle
# 'ilm import' thay toàn bộ cấu hình -> chạy lại không sinh rule trùng.
log "5. Lifecycle (ILM)"
mc ilm import siteA/logs >/dev/null <<'JSON'
{"Rules":[{"ID":"logs-expire-30d","Status":"Enabled","Filter":{"Prefix":""},"Expiration":{"Days":30}}]}
JSON
mc ilm import siteA/raw-data >/dev/null <<'JSON'
{"Rules":[{"ID":"raw-noncurrent-14d","Status":"Enabled","Filter":{"Prefix":""},"NoncurrentVersionExpiration":{"NoncurrentDays":14}}]}
JSON
# db-backup có versioning: Expiration chỉ đặt delete marker, nên cần thêm rule xóa version cũ
# và dọn delete marker còn trơ lại. Object Lock 1 ngày đã hết từ lâu khi tới ngày 7.
# Site Replication không chuyển rule ExpiredObjectDeleteMarker -> import lên cả 2 site.
BACKUP_ILM='{"Rules":[
 {"ID":"backup-expire-7d","Status":"Enabled","Filter":{"Prefix":""},"Expiration":{"Days":7},"NoncurrentVersionExpiration":{"NoncurrentDays":1}},
 {"ID":"backup-clean-delmarker","Status":"Enabled","Filter":{"Prefix":""},"Expiration":{"ExpiredObjectDeleteMarker":true}}
]}'
for s in siteA siteB; do mc ilm import "$s/db-backup" >/dev/null <<<"$BACKUP_ILM"; done
ok "logs: hết hạn sau 30 ngày; raw-data: noncurrent version hết hạn sau 14 ngày; db-backup: xóa sau 7 ngày"

# ------------------------------------------------------ 6. IAM least privilege
log "6. User ứng dụng + policy (không dùng root)"
ensure_user() {  # <access> <secret> <policy-name> <policy-file>
  local user=$1 secret=$2 policy=$3 file=$4
  mc admin policy create siteA "$policy" "$file" >/dev/null
  mc admin user add siteA "$user" "$secret" >/dev/null
  if ! mc admin user info siteA "$user" --json | grep -qE "\"policyName\":\"([^\"]*,)?$policy(,|\")"; then
    mc admin policy attach siteA "$policy" --user "$user" >/dev/null
  fi
  ok "user $user -> policy $policy"
}
ensure_user "$MLFLOW_APP_ACCESS_KEY" "$MLFLOW_APP_SECRET_KEY" mlflow-artifacts-rw policies/mlflow-artifacts-rw.json
ensure_user "$RAW_READER_ACCESS_KEY" "$RAW_READER_SECRET_KEY" raw-data-readonly  policies/raw-data-readonly.json
ensure_user "$INGEST_ACCESS_KEY"     "$INGEST_SECRET_KEY"     raw-data-ingest    policies/raw-data-ingest.json
ensure_user "$BACKUP_ACCESS_KEY"     "$BACKUP_SECRET_KEY"     db-backup-writer   policies/db-backup-writer.json

# ------------------------------------------------------------- 7. kiểm tra
log "7. Kiểm tra"
log "Chờ cấu hình đồng bộ sang siteB..."
for i in $(seq 1 30); do
  missing=0
  for b in "${BUCKETS[@]}"; do mc stat "siteB/$b" >/dev/null 2>&1 || missing=1; done
  mc admin user info siteB "$MLFLOW_APP_ACCESS_KEY" >/dev/null 2>&1 || missing=1
  for b in logs raw-data; do mc ilm rule ls "siteB/$b" >/dev/null 2>&1 || missing=1; done
  [[ $missing -eq 0 ]] && break
  sleep 2
done
[[ $missing -eq 0 ]] || die "Bucket/user/ILM chưa xuất hiện ở siteB sau 60s"

echo "--- mc admin replicate info siteA"
mc admin replicate info siteA
echo "--- mc admin replicate status siteA"
mc admin replicate status siteA

for s in siteA siteB; do
  echo "--- $s"
  for b in "${BUCKETS[@]}"; do
    printf '  %-17s versioning=%-8s sse=%-7s lock=%s\n' "$b" \
      "$(mc version info "$s/$b" --json | grep -o '"versioning":{"status":"[A-Za-z]*"' | cut -d'"' -f6 || echo '?')" \
      "$(mc encrypt info "$s/$b" --json | grep -o '"algorithm": *"[^"]*"' | cut -d'"' -f4 || echo none)" \
      "$(mc retention info --default "$s/$b" --json 2>/dev/null | grep -o '"mode": *"[A-Z]*"' | cut -d'"' -f4 || true)"
  done
done
ok "Setup hoàn tất"
