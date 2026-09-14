#!/usr/bin/env bash
set -euo pipefail
install -d -m 700 /var/backups/pds
cp -a /etc/apache2/sites-available/000-default.conf /var/backups/pds/before-saas-http.conf
cp -a /etc/apache2/sites-available/default-ssl.conf /var/backups/pds/before-saas-https.conf
cat > /etc/systemd/system/pds-api.service <<'SERVICE'
[Unit]
Description=PDS authentication API
After=postgresql.service network.target
Requires=postgresql.service
[Service]
User=pds-api
Group=pds-api
WorkingDirectory=/opt/pds/api
EnvironmentFile=/etc/pds/api.env
ExecStart=/opt/pds/node/bin/node --max-old-space-size=128 dist/main.js
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
UMask=0077
[Install]
WantedBy=multi-user.target
SERVICE
cat > /etc/apache2/sites-available/000-default.conf <<'HTTP'
<VirtualHost *:80>
  ServerName 15.252.37.89
  DocumentRoot /var/www/pds/current
  RewriteEngine On
  RewriteCond %{REQUEST_URI} !^/\.well-known/acme-challenge/
  RewriteRule ^ https://15.252.37.89%{REQUEST_URI} [R=301,L]
</VirtualHost>
HTTP
cat > /etc/apache2/sites-available/default-ssl.conf <<'HTTPS'
<VirtualHost *:443>
  ServerName 15.252.37.89
  DocumentRoot /var/www/pds/saas
  SSLEngine on
  SSLCertificateFile /etc/letsencrypt/live/pds-ip/fullchain.pem
  SSLCertificateKeyFile /etc/letsencrypt/live/pds-ip/privkey.pem
  ProxyPreserveHost On
  RequestHeader set X-Forwarded-Proto "https"
  RequestHeader unset X-Forwarded-For
  ProxyPass /api/ http://127.0.0.1:3000/api/ connectiontimeout=5 timeout=30
  ProxyPassReverse /api/ http://127.0.0.1:3000/api/
  Alias /tracker/ /var/www/pds/current/
  ErrorLog ${APACHE_LOG_DIR}/pds-error.log
  CustomLog ${APACHE_LOG_DIR}/pds-access.log combined
</VirtualHost>
HTTPS
cat > /etc/systemd/system/pds-cert-renew.service <<'RENEW'
[Unit]
Description=Renew short-lived PDS HTTPS certificate
[Service]
Type=oneshot
ExecStart=/opt/pds/certbot/bin/certbot renew --quiet --deploy-hook "/usr/sbin/apache2ctl configtest && /bin/systemctl reload apache2"
RENEW
cat > /etc/systemd/system/pds-cert-renew.timer <<'TIMER'
[Unit]
Description=Check PDS HTTPS renewal twice daily
[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=900
Persistent=true
[Install]
WantedBy=timers.target
TIMER
install -d -o postgres -g postgres -m 700 /var/backups/pds/database
cat > /etc/systemd/system/pds-db-backup.service <<'BACKUP'
[Unit]
Description=Daily local PDS database backup
After=postgresql.service
[Service]
Type=oneshot
User=postgres
ExecStart=/bin/sh -c 'umask 077; /usr/bin/pg_dump -Fc pds_saas > /var/backups/pds/database/pds-$(date +%%u).dump'
BACKUP
# Allow postgres to traverse the root-owned backup parent, not list it.
chmod 711 /var/backups/pds
cat > /etc/systemd/system/pds-db-backup.timer <<'TIMER'
[Unit]
Description=Daily PDS database backup
[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
[Install]
WantedBy=timers.target
TIMER
a2enmod proxy proxy_http headers rewrite ssl
apache2ctl configtest
systemctl daemon-reload
systemctl enable --now pds-api pds-cert-renew.timer pds-db-backup.timer
systemctl start pds-db-backup.service
systemctl reload apache2
printf 'Services and HTTPS activated\n'
