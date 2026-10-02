#!/usr/bin/env bash
# Sinh .env từ .env.example với bí mật ngẫu nhiên. Không ghi đè .env đã có.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
  echo "[gen_env] .env đã tồn tại -> giữ nguyên"
  exit 0
fi

rand() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true; }
kms()  { head -c 32 /dev/urandom | base64 | tr -d '\n'; }

while IFS= read -r line || [[ -n "$line" ]]; do
  while [[ "$line" == *__RANDOM__* ]]; do line="${line/__RANDOM__/$(rand)}"; done
  line="${line/__KMS_KEY__/$(kms)}"
  line="${line%%  *#*}"   # bỏ comment cuối dòng (compose không hỗ trợ trong giá trị)
  printf '%s\n' "$line"
done < .env.example > .env

echo "[gen_env] Đã tạo .env với bí mật ngẫu nhiên"
