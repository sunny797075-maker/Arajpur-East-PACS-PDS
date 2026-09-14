#!/usr/bin/env bash
set -euo pipefail

APP_HOST="${1:?public host or IP is required}"
APP_ORIGIN="http://${APP_HOST}"
REPO_URL="https://github.com/sunny797075-maker/PDS-Connect.git"

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq ca-certificates curl git nginx postgresql postgresql-contrib

pg_hba="$(find /etc/postgresql -path '*/main/pg_hba.conf' -print -quit)"
if [ -n "$pg_hba" ] && ! grep -Fq "pds_auth_runtime,pds_tenant_runtime,pds_platform_runtime" "$pg_hba"; then
  cp "$pg_hba" "${pg_hba}.before-pds-connect"
  sed -i "1ilocal pds_saas pds_auth_runtime,pds_tenant_runtime,pds_platform_runtime scram-sha-256" "$pg_hba"
  systemctl restart postgresql
fi

if ! command -v node >/dev/null 2>&1 || ! node -v | grep -Eq '^v22\.'; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y -qq nodejs
fi

id pds-api >/dev/null 2>&1 || useradd --system --home /opt/pds/api --shell /usr/sbin/nologin pds-api
install -d -m 755 /opt/pds /var/www/pds-connect /var/backups/pds/database
chmod 700 /var/backups/pds/database

if [ ! -d /opt/pds/source/.git ]; then
  rm -rf /opt/pds/source
  git clone "$REPO_URL" /opt/pds/source
else
  git -C /opt/pds/source fetch origin main
  git -C /opt/pds/source reset --hard origin/main
fi

install -d -m 700 /etc/pds
if [ ! -f /etc/pds/api.env ]; then
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q -d postgres -c "CREATE DATABASE pds_saas;" 2>/dev/null || true
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q -d pds_saas -f /opt/pds/source/saas/database/001_schema.sql
  if [ -f /opt/pds/source/saas/database/002_workflows.sql ]; then
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q -d pds_saas -f /opt/pds/source/saas/database/002_workflows.sql
  fi

  jwt_secret="$(openssl rand -hex 64)"
  token_pepper="$(openssl rand -hex 64)"
  otp_pepper="$(openssl rand -hex 64)"
  auth_password="$(openssl rand -hex 32)"
  tenant_password="$(openssl rand -hex 32)"
  platform_password="$(openssl rand -hex 32)"

  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q -d postgres <<SQL
CREATE ROLE pds_auth_runtime LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD '${auth_password}' IN ROLE pds_auth;
CREATE ROLE pds_tenant_runtime LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD '${tenant_password}' IN ROLE pds_tenant;
CREATE ROLE pds_platform_runtime LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD '${platform_password}' IN ROLE pds_platform;
SQL

  cat > /etc/pds/api.env <<ENV
NODE_ENV=development
PORT=3000
DB_SSL=false
MAIL_MODE=disabled
MAIL_FROM=unconfigured@example.invalid
CORS_ORIGINS=${APP_ORIGIN}
AWS_REGION=ap-south-1
TERMS_VERSION=foundation-2026-09
JWT_ISSUER=pds-saas
JWT_AUDIENCE=pds-clients
AUTH_DATABASE_URL=postgresql://pds_auth_runtime:${auth_password}@localhost/pds_saas?host=/var/run/postgresql
TENANT_DATABASE_URL=postgresql://pds_tenant_runtime:${tenant_password}@localhost/pds_saas?host=/var/run/postgresql
PLATFORM_DATABASE_URL=postgresql://pds_platform_runtime:${platform_password}@localhost/pds_saas?host=/var/run/postgresql
JWT_SECRET=${jwt_secret}
TOKEN_PEPPER=${token_pepper}
OTP_PEPPER=${otp_pepper}
ENV
  chmod 600 /etc/pds/api.env
else
  sed -i "s#^CORS_ORIGINS=.*#CORS_ORIGINS=${APP_ORIGIN}#" /etc/pds/api.env
fi

cd /opt/pds/source/saas/backend
rm -rf dist
tar -xzf /tmp/pds-backend-dist.tar.gz -C .
npm ci --omit=dev --no-audit --no-fund

rm -rf /opt/pds/api
install -d -o pds-api -g pds-api -m 755 /opt/pds/api
cp -a package.json package-lock.json node_modules dist /opt/pds/api/
chown -R pds-api:pds-api /opt/pds/api

cat > /etc/systemd/system/pds-api.service <<'SERVICE'
[Unit]
Description=PDS Connect API
After=postgresql.service network.target
Requires=postgresql.service

[Service]
User=pds-api
Group=pds-api
WorkingDirectory=/opt/pds/api
EnvironmentFile=/etc/pds/api.env
ExecStart=/usr/bin/node --max-old-space-size=256 dist/main.js
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
SERVICE

rm -rf /var/www/pds-connect/*
tar -xzf /tmp/pds-web.tar.gz -C /var/www/pds-connect
find /var/www/pds-connect -type d -exec chmod 755 {} \;
find /var/www/pds-connect -type f -exec chmod 644 {} \;

cat > /etc/nginx/sites-available/pds-connect <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${APP_HOST};

    root /var/www/pds-connect;
    index index.html;

    client_max_body_size 10m;

    location /api/ {
        proxy_pass http://127.0.0.1:3000/api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
NGINX

rm -f /etc/nginx/sites-enabled/default
ln -sfn /etc/nginx/sites-available/pds-connect /etc/nginx/sites-enabled/pds-connect
nginx -t

systemctl daemon-reload
systemctl enable --now pds-api
systemctl restart pds-api
systemctl reload nginx

for i in $(seq 1 20); do
  if curl -fsS http://127.0.0.1:3000/api/v1/health >/dev/null; then
    break
  fi
  sleep 1
done

curl -fsS http://127.0.0.1:3000/api/v1/health
printf '\nPDS Connect deployed at %s\n' "$APP_ORIGIN"
