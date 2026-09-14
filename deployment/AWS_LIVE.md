# Live PDS authentication deployment

Verified on 13 September 2026.

## Registration update — 14 September 2026

Public signup is now live at https://15.252.37.89/#/distributor/register, linked from the distributor login page. It creates an isolated ACTIVE distributor account, shows its generated Distributor ID with a copy action, and carries that ID into sign-in. Existing accounts can sign in at https://15.252.37.89/#/distributor/login. There is no public Super Admin signup or navigation link.

The signup transaction creates the hashed-password user, profile, sequence-generated unique ID, distributor membership, usage row and audit event. Email and mobile are not falsely marked verified, and no subscription is created. Retrying the same email/mobile/password returns the original ID without changing data; conflicting credentials return 409. Signup is rate-limited. This self-registration flow supersedes the earlier statements below that distributor enrollment is unavailable. Email recovery remains unconfigured.

Web release: `/var/www/pds/saas-releases/20260914T034542Z`; previous API backup: `/var/backups/pds/update-20260914T034542Z`. No database migration was required. Backend checks passed, all 14 existing Flutter tests passed, and three additional signup-to-ID-to-sign-in tests passed at 320/768/1440 pixels. Live public signup, retry handling, conflict feedback, real login, own-profile access and platform denial passed; the temporary account was removed. Owner authentication and deployed asset checks also passed.

## Branding and profile update — 14 September 2026

The login footer now reads `Powered by MENHI GLOBAL TECH`. Fixed Arajpur contact details and the public Super Admin navigation link have been removed from the Flutter login pages. The dedicated admin route remains `/#/super-admin/login`, accessible directly and protected by admin authentication; removing a public link does not make the URL network-private.

Distributor sessions now contain only their own organization name, address and phone from the server profile, and their dashboard displays these values. Session refresh picks up profile changes. Super Admin responses contain no distributor profile.

Activated web release: `/var/www/pds/saas-releases/20260914T031535Z`. Previous API backup: `/var/backups/pds/update-20260914T031535Z`. No database migration was required. Fourteen Flutter tests, five backend tests, static analysis, and live owner/distributor/profile refresh checks passed. Live web assets matched the compiled files, and temporary verification accounts were removed.

- Flutter web: https://15.252.37.89/
- Super Admin: https://15.252.37.89/#/super-admin/login
- Distributor: https://15.252.37.89/#/distributor/login
- Database health: https://15.252.37.89/api/v1/health
- Preserved offline tracker: https://15.252.37.89/tracker/

The live build has **demo mode disabled**. PostgreSQL and the NestJS API are running on the existing Lightsail LAMP-1 instance in ap-south-1. No new paid AWS instance, RDS database or storage service was created. This 512 MB instance is suitable for a small authentication pilot, not an assessed production SaaS workload.

## Runtime and isolation

Apache terminates trusted HTTPS and proxies /api/ to 127.0.0.1:3000. PostgreSQL listens only on its local Unix socket, not TCP. Three distinct non-superuser, non-BYPASSRLS database login roles separate identity, platform metadata and tenant business access. Tenant tables use FORCE ROW LEVEL SECURITY, with distributor identity derived from the verified server session.

Exactly two roles exist in this fresh database: SUPER_ADMIN and DISTRIBUTOR. At this phase there is one account per distributor. Super Admin has platform metadata permissions and no tenant business-data route. The previous future-facing staff-role plan is superseded for this authentication phase.

API files: /opt/pds/api. Server-only environment: /etc/pds/api.env (mode 600). Flutter files: /var/www/pds/saas. The original tracker remains at /var/www/pds/current. Service: pds-api.service. Runtime uses Node 22 with a bounded heap, limited PostgreSQL connection pools, and 1 GB server swap. No PC security settings were changed.

## Owner access

Initial owner ID: ADMIN-001. The generated password is in the user's private local file `C:\Users\DELL\.aws\pds-owner-login.txt`. It is outside the project and was never included in logs, Git, web assets or chat. No default/demo password is valid on AWS. No email address has been asserted or marked verified for this owner. Account email can be assigned when the owner supplies it.

Real distributor accounts have not been enrolled. Two temporary verification accounts were created, tested, and deleted. Public registration and recovery delivery are disabled until the corresponding account-provisioning and email setup is completed. These limitations are explicit, not silent success responses. The dashboard business modules remain placeholders as requested.

The earlier production-MFA development gate is replaced by the explicitly requested two-type password-login foundation. MFA is not implemented; this deployment must not be described as MFA-protected.

## Certificates and backups

Trusted Let's Encrypt IP certificate: /etc/letsencrypt/live/pds-ip. IP certificates are short-lived. pds-cert-renew.timer checks renewal twice daily and reloads Apache after renewal. A staging renewal dry run passed. HTTP redirects to HTTPS except the certificate challenge path.

pds-db-backup.timer creates a daily PostgreSQL custom-format dump in /var/backups/pds/database, rotating seven weekday files. An initial backup was created. These are local server backups, not off-instance disaster recovery. No restore drill has been completed. Apache's original configuration is preserved in /var/backups/pds/before-saas-http.conf and before-saas-https.conf.

The database is a fresh authentication schema. Device LocalStorage records, the old GitHub private JSON store and beneficiary business records were not imported or exposed.

## Verification

- Backend typecheck, build and five automated tests passed, including ID login and remembered-session contract assertions.
- Live HTTPS owner login and access to platform metadata passed; owner business profile access was denied.
- Live distributor A/B login, correct own profile, denied platform access, PostgreSQL RLS boundaries, and suspension enforcement passed.
- Browser HttpOnly/Secure/SameSite cookies, CSRF checks, refresh-token rotation/replay rejection and logout revocation passed.
- The public demo password was rejected.
- Flutter index, bootstrap and main bundle matched local build bytes; private file paths returned 404; the original tracker still returned 200.
- Temporary SSH keys and the deployment-only IPv6 firewall exception were removed after verification.

## Operations

Run on the server:

```bash
sudo systemctl status pds-api --no-pager
sudo journalctl -u pds-api -n 40 --no-pager
sudo systemctl list-timers pds-cert-renew.timer pds-db-backup.timer
sudo systemctl start pds-db-backup.service
sudo /opt/pds/certbot/bin/certbot renew --dry-run
```

The schema file now represents this first two-role deployment. Do not rerun it against an existing database; later changes require versioned migrations and backups.
