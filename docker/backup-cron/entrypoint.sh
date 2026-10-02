#!/bin/sh
# busybox crond không truyền biến môi trường của container cho job,
# nên lưu lại để backup_db.sh tự nạp.
set -eu
export -p > /etc/backup.env
echo "${BACKUP_SCHEDULE} bash /scripts/backup_db.sh >> /proc/1/fd/1 2>&1" > /etc/crontabs/root
echo "[backup-cron] lịch: ${BACKUP_SCHEDULE} -> /scripts/backup_db.sh"
exec crond -f -l 8
