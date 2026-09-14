#!/usr/bin/env bash
set -euo pipefail
tag=$(date -u +%Y%m%dT%H%M%SZ)
backup="/var/backups/pds/database/pre-workflows-$tag.dump"
runuser -u postgres -- pg_dump -Fc pds_saas > "$backup"
chmod 600 "$backup"
test -s "$backup"
exists=$(runuser -u postgres -- psql -d pds_saas -Atc "SELECT to_regclass('control.schema_migrations') IS NOT NULL")
if [ "$exists" = t ]; then
  applied=$(runuser -u postgres -- psql -d pds_saas -Atc "SELECT count(*) FROM control.schema_migrations WHERE version='002_workflows'")
else
  applied=0
fi
if [ "$applied" = 0 ]; then
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d pds_saas -f /tmp/002_workflows.sql
fi
printf 'Migration verified. Database backup: %s\n' "$backup"
