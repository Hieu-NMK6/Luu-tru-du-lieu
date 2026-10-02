#!/usr/bin/env bash
# Sinh CA nội bộ + chứng chỉ self-signed cho minio-a, minio-b (TLS KHÔNG bật mặc định).
# Kết quả: certs/ca.crt, certs/minio-{a,b}/{public.crt,private.key,CAs/ca.crt}
# Dùng: bash scripts/gen_certs.sh [--force]
set -euo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1
log() { echo "[$(date +%H:%M:%S)] [certs] $*"; }

command -v openssl >/dev/null || { echo "Cần openssl (Git Bash có sẵn)"; exit 1; }
if [[ -f certs/ca.crt && "${1:-}" != "--force" ]]; then
  log "certs/ đã có -> giữ nguyên (dùng --force để sinh lại)"
  exit 0
fi
rm -rf certs && mkdir -p certs

cat > certs/ca.cnf <<'EOF'
[req]
prompt = no
distinguished_name = dn
x509_extensions = v3_ca
[dn]
CN = LTDL-N13 Demo CA
O = LTDL-N13
[v3_ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 825 -sha256 \
  -keyout certs/ca.key -out certs/ca.crt -config certs/ca.cnf 2>/dev/null
log "CA: certs/ca.crt"

for site in minio-a minio-b; do
  d="certs/$site"; mkdir -p "$d/CAs"
  cat > "$d/req.cnf" <<EOF
[req]
prompt = no
distinguished_name = dn
req_extensions = v3
[dn]
CN = $site
O = LTDL-N13
[v3]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:$site, DNS:localhost, IP:127.0.0.1
EOF
  openssl req -newkey rsa:2048 -nodes -keyout "$d/private.key" -out "$d/req.csr" -config "$d/req.cnf" 2>/dev/null
  openssl x509 -req -in "$d/req.csr" -CA certs/ca.crt -CAkey certs/ca.key -CAcreateserial \
    -days 825 -sha256 -extfile "$d/req.cnf" -extensions v3 -out "$d/public.crt" 2>/dev/null
  cp certs/ca.crt "$d/CAs/ca.crt"          # để 2 site tin nhau khi replicate qua HTTPS
  rm -f "$d/req.csr" "$d/req.cnf"
  log "$site: $(openssl x509 -in "$d/public.crt" -noout -ext subjectAltName | tail -1 | xargs)"
done
rm -f certs/ca.cnf certs/ca.srl
log "Xong. Cách bật TLS: xem docs/security.md"
