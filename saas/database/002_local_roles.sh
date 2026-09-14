#!/usr/bin/env bash
set -euo pipefail
psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set=ON_ERROR_STOP=1 \
  --set=auth_password="$PDS_AUTH_PASSWORD" --set=tenant_password="$PDS_TENANT_PASSWORD" --set=platform_password="$PDS_PLATFORM_PASSWORD" <<'SQL'
CREATE USER pds_api_auth PASSWORD :'auth_password' IN ROLE pds_auth;
CREATE USER pds_api_tenant PASSWORD :'tenant_password' IN ROLE pds_tenant;
CREATE USER pds_api_platform PASSWORD :'platform_password' IN ROLE pds_platform;
SQL
