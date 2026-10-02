FROM quay.io/minio/mc:RELEASE.2025-04-16T18-13-26Z AS mc

# Cùng major version với postgres-a để pg_dump tương thích
FROM postgres:16.15-alpine
RUN apk add --no-cache bash tzdata
COPY --from=mc /usr/bin/mc /usr/bin/mc
COPY docker/backup-cron/entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
