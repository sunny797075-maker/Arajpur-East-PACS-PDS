#!/usr/bin/env bash
set -euo pipefail
tag=$(date -u +%Y%m%dT%H%M%SZ)
backup="/var/backups/pds/update-$tag"
release="/var/www/pds/saas-releases/$tag"
install -d -m 700 "$backup"
install -d -m 755 "$release"
cp -a /opt/pds/api/dist "$backup/dist"
tar -xzf /tmp/pds-saas-web.tar.gz -C "$release" --no-same-owner
find "$release" -type d -exec chmod 755 {} +
find "$release" -type f -exec chmod 644 {} +
test -s "$release/main.dart.js"
tar -xzf /tmp/pds-api-update.tar.gz -C /opt/pds/api --no-same-owner
systemctl restart pds-api
ready=false
for attempt in $(seq 1 20); do
  if curl -fsS http://127.0.0.1:3000/api/v1/health >/dev/null; then ready=true; break; fi
  sleep 1
done
if [ "$ready" != true ]; then
  cp -a "$backup/dist/." /opt/pds/api/dist/
  systemctl restart pds-api
  printf 'API update failed; prior API restored.\n' >&2
  exit 1
fi
ln -s "$release" /var/www/pds/saas.next
if [ -d /var/www/pds/saas ] && [ ! -L /var/www/pds/saas ]; then
  mv /var/www/pds/saas "/var/www/pds/saas-releases/previous-$tag"
fi
mv -Tf /var/www/pds/saas.next /var/www/pds/saas
printf 'Updated web release: %s\nAPI backup: %s\n' "$release" "$backup"
