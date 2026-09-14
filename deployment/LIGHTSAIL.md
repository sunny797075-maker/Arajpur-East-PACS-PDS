# Lightsail deployment

Deployed 13 September 2026 to existing instance `LAMP-1`, Mumbai (`ap-south-1`).

- Preview: http://15.252.37.89/
- Existing static IP: `StaticIp-1`, already attached to LAMP-1.
- Apache document root: `/var/www/pds/current`.
- Release: `/var/www/pds/releases/20260913T164617Z`.
- Original Apache configuration backup: `/var/backups/pds/apache-20260913T164617Z`.
- Original default web files remain in `/var/www/html`.
- Only index.html, sw.js, css/style.css and the three js files were uploaded.
- The multi-tenant NestJS foundation and Flutter application were not deployed as a backend.

All six public assets returned HTTP 200 and matched local SHA-256 hashes. The 11 tracker tests passed. Requests to data.json, .git/config, saas/backend/.env and phpmyadmin/ returned 404.

## HTTPS and existing data

This is an HTTP preview. The instance still has its original self-signed TLS certificate; do not bypass browser certificate warnings. Configure a domain and a trusted TLS certificate before operational use. The service worker requires HTTPS for offline page loading. LocalStorage belongs to each browser origin: data from localhost or GitHub Pages does not automatically appear here. Use Export Backup and Restore Backup to move your records, preferably after the final HTTPS address is set up.

## Rollback

Run on the Lightsail server:

```bash
sudo cp /var/backups/pds/apache-20260913T164617Z/000-default.conf /etc/apache2/sites-available/
sudo cp /var/backups/pds/apache-20260913T164617Z/default-ssl.conf /etc/apache2/sites-available/
sudo a2disconf pds-static
sudo apache2ctl configtest && sudo systemctl reload apache2
```

AWS CLI uses profile `pds-lightsail`; browser login credentials expire automatically. No AWS credentials were placed in this project. Direct IPv4 SSH timed out; deployment succeeded over IPv6 with host keys verified against the AWS API. The temporary source-IP SSH exception and SSH credentials were removed after deployment. No PC firewall or security settings were changed.
