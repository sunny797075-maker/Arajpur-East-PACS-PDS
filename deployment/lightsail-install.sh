#!/usr/bin/env bash
set -euo pipefail
archive=${1:?Pass the uploaded public-assets tar archive}
release="/var/www/pds/releases/$(date -u +%Y%m%dT%H%M%SZ)"
backup="/var/backups/pds/apache-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 755 "$release" /var/www/pds
install -d -m 700 "$backup"
cp -a /etc/apache2/sites-available/000-default.conf "$backup/"
cp -a /etc/apache2/sites-available/default-ssl.conf "$backup/"
tar -xzf "$archive" -C "$release" --no-same-owner
find "$release" -type d -exec chmod 755 {} +
find "$release" -type f -exec chmod 644 {} +
test -s "$release/index.html"
ln -s "$release" /var/www/pds/current.next
mv -Tf /var/www/pds/current.next /var/www/pds/current
for site in 000-default default-ssl; do
  sed -i 's@DocumentRoot /var/www/html@DocumentRoot /var/www/pds/current@' "/etc/apache2/sites-available/$site.conf"
done
cat > /etc/apache2/conf-available/pds-static.conf <<'APACHE'
<Directory /var/www/pds>
    Options -Indexes -ExecCGI +FollowSymLinks
    AllowOverride None
    Require all granted
    <IfModule mod_headers.c>
        Header always set X-Content-Type-Options "nosniff"
        Header always set Referrer-Policy "strict-origin-when-cross-origin"
        Header always set X-Frame-Options "DENY"
        Header set Cache-Control "no-cache"
    </IfModule>
</Directory>
APACHE
a2enmod headers
a2enconf pds-static
if ! apache2ctl configtest; then
  cp "$backup/000-default.conf" /etc/apache2/sites-available/
  cp "$backup/default-ssl.conf" /etc/apache2/sites-available/
  a2disconf pds-static
  exit 1
fi
systemctl reload apache2
printf 'Release: %s\nApache backup: %s\n' "$release" "$backup"
