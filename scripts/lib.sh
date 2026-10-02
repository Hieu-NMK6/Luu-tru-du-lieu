# Hàm dùng chung cho các script chạy trên host. Dùng: source "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MSYS_NO_PATHCONV=1   # Git Bash: không tự đổi "/path" thành "C:/Program Files/Git/path"

log()  { printf '\033[1;34m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m[%s] OK  %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[%s] !!  %s\033[0m\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '\033[1;31m[%s] ERR %s\033[0m\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

[[ -f "$ROOT/.env" ]] || die "Thiếu .env — chạy 'make env' trước"
set -a; source "$ROOT/.env"; set +a
unset TZ   # TZ=Asia/... không hợp lệ với Git Bash; compose tự đọc TZ từ .env

# mc: ưu tiên bản trong PATH, nếu không có thì dùng ./bin/mc(.exe)
if command -v mc >/dev/null 2>&1; then MC=mc
elif [[ -x "$ROOT/bin/mc.exe" ]]; then MC="$ROOT/bin/mc.exe"
elif [[ -x "$ROOT/bin/mc" ]]; then MC="$ROOT/bin/mc"
else die "Không tìm thấy mc (cài vào PATH hoặc đặt vào ./bin)"; fi
mc() { "$MC" --no-color "$@"; }

# Khi bật TLS (docker-compose.tls.yml), MinIO từ chối HTTP -> dùng https và thêm file override.
# Thử cả 2 site: lúc failover site A có thể đã sập.
SCHEME=http; COMPOSE_FILES=()
if ! curl -sf http://localhost:9000/minio/health/live >/dev/null    && ! curl -sf http://localhost:9100/minio/health/live >/dev/null; then
  SCHEME=https; COMPOSE_FILES=(-f docker-compose.yml -f docker-compose.tls.yml)
fi
compose() { (cd "$ROOT" && docker compose "${COMPOSE_FILES[@]}" "$@"); }
