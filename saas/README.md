# PDS SaaS — Phase 1–2 foundation

Read [ARCHITECTURE.md](ARCHITECTURE.md) first. It contains the system architecture, ER diagram, schema ownership, authentication, API/payment design, Flutter feature structure, platform-admin boundaries, AWS deployment design and risk controls requested in the master prompt.

This is a **new** NestJS/PostgreSQL SaaS foundation. It does not turn GitHub Pages or the earlier GitHub-file app into a tenant database. The current live tracker is preserved. No AWS deployment, paid billing flow or complete SaaS Flutter UI is claimed in this phase.

## Included

- An executable PostgreSQL schema covering all planned domains, with separate identity/platform/tenant schemas, non-owner application roles, forced tenant RLS, composite tenant foreign keys and append-only transaction/audit grants.
- Strictly validated registration for PACS, independent, other and custom organization types. PACS is optional.
- Email/mobile OTP delivery adapters (local SMTP/SES and SNS), expiring challenges with persisted attempt budgets, one-time distributor creation after verification, and an approval step.
- Scrypt password hashing; email/mobile login with verified-contact checks; short access JWTs; hashed, rotating refresh tokens; session revocation; logout-all; password reset.
- Tenant profile read/update and platform distributor list/status changes, with database-derived session membership/permissions. No platform beneficiary-data route.
- Native-token and browser HttpOnly-cookie session paths, CSRF validation, origin checks, security headers, body limits and shared PostgreSQL rate counters.
- Security/validation tests and an embedded real-PostgreSQL-engine RLS test using PGlite. This is complementary to, not a substitute for, running the complete API integration suite against the production PostgreSQL version.

## Local run

Requires Node 22+, npm, and Docker with Compose (or an existing PostgreSQL instance and an SMTP service).

From `saas/`:

```powershell
node tools/setup-local.mjs
docker compose --env-file .env.local up -d
cd backend
npm install
npm run typecheck
npm test
npm run build
node --env-file=../.env.local dist/main.js
```

The environment generator creates random local-only secrets and never prints them. `.env.local` is ignored by Git. Preserve it while the database volume exists; do not run a destructive volume reset to change credentials. The local PostgreSQL administrator credentials are not supplied to the running API.

Local API: `http://localhost:3000/api/v1`; email inbox: `http://localhost:8025`. Local development can test email OTP without sending a real message. SNS mobile delivery requires the owner's AWS account, approved sender configuration and IAM permissions; no fake SMS sender is substituted.

The initial administrator is provisioned separately through `src/bootstrap-admin.ts`. Set `MIGRATION_DATABASE_URL` and the `BOOTSTRAP_ADMIN_EMAIL`, `BOOTSTRAP_ADMIN_MOBILE`, `BOOTSTRAP_ADMIN_PASSWORD`, and `BOOTSTRAP_ADMIN_NAME` environment values to your chosen local development account, then run `npx tsx src/bootstrap-admin.ts`. There are no default admin passwords. The script refuses production use. It never promotes an existing account silently.

Registration returns a challenge ID. Read the code in Mailpit, verify it, sign in as the development platform administrator and activate the new distributor with a reason. Only then can that distributor sign in. Phone login requires separate mobile verification. Password reset uses the verified email channel.

## Implemented endpoints

All routes are under `/api/v1`.

| Method | Route | Purpose |
|---|---|---|
| GET | /health | Service liveness |
| GET | /organization-types | Active, configurable organization catalog |
| POST | /auth/register | Pending identity and email OTP |
| POST | /auth/resend-otp | Email/mobile verification challenge |
| POST | /auth/verify-otp | Consume OTP and provision pending distributor once |
| POST | /auth/login | Verified email/mobile and password; WEB or NATIVE session |
| POST | /auth/refresh | Rotate refresh credentials |
| GET | /auth/me | Session identity and effective permissions |
| POST | /auth/logout | Revoke current session |
| POST | /auth/logout-all | Revoke all user sessions |
| POST | /auth/forgot-password | Enumeration-resistant reset challenge |
| POST | /auth/reset-password | Consume reset OTP, update password, revoke sessions |
| GET/PATCH | /distributor/me | Authorized tenant profile |
| GET | /admin/distributors | Platform-only profile list, search and pagination |
| PATCH | /admin/distributors/:id/status | Audited account approval/suspension/closure |

Native login body includes `clientType: "NATIVE"`; store its refresh token only in OS secure storage. Browser login includes `clientType: "WEB"`; send requests with credentials and an allowlisted Origin. Browser refresh uses the HttpOnly `pds_refresh` cookie and `X-CSRF-Token` matching the readable `pds_csrf` cookie. Production Flutter Web and API should share a site/origin via CloudFront `/api/*` routing so the application can read its CSRF cookie. Do not store a browser refresh token in localStorage.

The database allows multi-organization memberships. If an identity has more than one active membership, login must include an `organizationCode` that is verified against the user's memberships. Business APIs never take a caller-selected tenant ID.

## Deliberate phase boundaries

Later module tables are created to stabilize ownership/FKs, but beneficiary CRUD/import screens, commodity/stock mutation services, payment webhooks/invoices, entitlement enforcement, document scanning/S3 upload, reports, notifications, platform MFA, new Flutter clients and AWS IaC are **not implemented yet**. There are no fake gateway-success handlers or stub business routes pretending to implement them.

The first tenant profile update currently covers contact/address/name fields. Changing organization type, staff management and protected registration fields will be added with their own audited validation flow. The production platform-admin login is blocked until MFA enrollment is implemented.

Before deployment, run actual PostgreSQL/API integration tests for concurrent OTP consumption, refresh reuse, suspension, tenant isolation and transactional audit behavior. Configure verified TLS/SES, secrets, trusted reverse-proxy addresses, cleanup jobs for expired challenges/rate counters, shared logging/alerts, production terms/privacy content, backups and restore tests. Never expose this development foundation as the finished commercial SaaS.
