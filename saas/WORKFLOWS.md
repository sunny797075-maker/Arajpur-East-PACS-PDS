# PDS Connect core workflows

The Flutter client uses the authenticated NestJS API. Business records never accept a distributor ID from the client: the server derives ownership from the current session and PostgreSQL enforces it with forced row-level security. Super Admin's database role has no access to beneficiary, distribution, staff or attendance tables.

## Distributor workspace

- Beneficiaries: add/edit/archive, search by card/name/mobile, PHH/AAY category and units.
- CSV/XLSX import: first worksheet, header aliases, 500 rows/5 MB limit, validation preview and atomic import. Store RC/mobile cells as text; numeric Excel cells cannot recover zeros already lost in the source file. Duplicate cards, including archived cards, are rejected.
- Distribution: monthly cycles, current and historical month selector, immutable timestamped receipts and a beneficiary snapshot. Duplicate clicks/retries cannot create a second distribution for the same card/month.
- Remaining: selected-cycle pending list, distribute and native dialer actions.
- Staff: up to three active members; staff records do not create additional login roles.
- Attendance: dated present/absent updates, staff history and monthly totals. Future attendance is rejected.
- Dashboard: live beneficiary, distribution, remaining, today's distribution, active staff and today's present counts. Dates use Asia/Kolkata on the server.
- Profile: edit the distributor's own address and organization details.

Inventory, stock, products and other unnecessary planned modules are absent from navigation.

## Platform access and payments

Super Admin can browse profiles, suspend accounts, create/enable/disable plans, record actual payment receipts and inspect payment/access history. Recording a receipt extends access by the selected plan's duration and activates the account. Receipt references are unique and repeat submissions do not extend access twice. Existing plan snapshots stay with payments.

Approve Without Payment records a reason and extends access without marking an unpaid distributor as paid. Access records are append-only. New registrations can sign in but need payment or explicit approval to operate business modules. Existing active accounts receive 30 days of migration access so deployment does not unexpectedly interrupt them.

Online payment gateway collection is not configured. The current payment action is an authenticated administrator's acknowledgement of money actually received, not an online checkout or an unverified client-side success flag. Gateway credentials and a verified callback integration are required before enabling online collection.

## Deployment

Apply `database/002_workflows.sql` once, with `deployment/migrate-workflows.sh`, before updating API and web artifacts. It creates a PostgreSQL dump before migration. Do not rerun schema 001 against existing data. `deployment/verify-live-workflows.cjs` tests HTTPS flows using temporary isolated tenants and removes those fixtures afterward.

```powershell
cd saas/backend
npm test
npm run build
cd ../flutter_client
flutter test
flutter analyze
flutter build web --release --dart-define=PDS_API_URL=https://15.252.37.89/api/v1
```

These centralized modules require an API connection; failed writes show an error rather than claiming local-only success. The separate legacy offline tracker is unchanged.

Distributor sign-in uses registered email or mobile number and password only. Indian mobile numbers accept 10 digits, 91-prefixed digits, or +91 format. Email matching is case-insensitive. Distributor IDs are retained for tenant isolation, but rejected as login credentials. This update is prepared locally; AWS publication still requires renewed authentication.
