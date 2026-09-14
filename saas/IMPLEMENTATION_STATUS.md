# Delivery status

## Existing live deployment

PDS Connect authentication, public distributor registration and a private PostgreSQL database are hosted at https://15.252.37.89/. Super Admin login remains a separate, unlinked route. See [AWS operations](../deployment/AWS_LIVE.md).

## Core workflow update — built locally, deployment pending

Implemented beneficiary CRUD/archive, transactional CSV/XLSX imports, monthly distribution and remaining lists, native calling, three-active-member staff management, attendance history, live metrics and profile editing. Super Admin has profile/access controls, plan management, payment receipts/history and manual approval without payment. Inventory and unnecessary planned modules have been removed from navigation.

See [workflow behavior and migration instructions](WORKFLOWS.md). Database migration 002 is additive and preserves existing records. It must be applied with a backup before the new API/web bundle is published.

Verification: 6 backend test cases, 23 Flutter tests, TypeScript compilation and Flutter analysis passed. Release web and Android debug APK builds succeeded. Tests include actual PostgreSQL RLS behavior, monthly distribution idempotency, staff ownership/limits, attendance updates, payment replay safety, real XLSX parsing and phone/tablet/desktop interaction layouts.

AWS publishing currently requires renewed browser authentication because AWS rejected the saved login session and the new browser authorization expired without completing. No workflow migration or deployment has been applied yet. Once authenticated, `deployment/deploy-workflows.ps1` uploads the artifacts, backs up/migrates PostgreSQL, publishes API/web, tests live workflows and removes temporary SSH credentials/access.

## Remaining external configuration / validation

- Online payment gateway credentials and verified callback integration; current receipts are manually acknowledged by authenticated Super Admin.
- Email/SMS recovery delivery and optional MFA.
- Owner-controlled release signing, iOS compilation on macOS, physical-device testing and production load/security testing.
- Disaster recovery restore drills and off-server backups.

The separate legacy offline tracker is preserved. New centralized workflows require the API connection and do not silently pretend failed writes succeeded.

Distributor sign-in uses registered email or mobile number and password only. Indian mobile numbers accept 10 digits, 91-prefixed digits, or +91 format. Email matching is case-insensitive. Distributor IDs are retained for tenant isolation, but rejected as login credentials. This update is prepared locally; AWS publication still requires renewed authentication.
