# PDS Connect — Flutter authentication foundation

This Flutter client has exactly two account types: Super Admin and Distributor. Core beneficiary, distribution, staff, attendance and platform-access workflows are implemented; see [workflow documentation](../WORKFLOWS.md) and [current delivery status](../IMPLEMENTATION_STATUS.md). Demo mode previews authentication only; business modules require the API.

**AWS update:** The live API-backed web app is now at https://15.252.37.89/. Demo mode is disabled there. See [live deployment status](../../deployment/AWS_LIVE.md) for credentials location, verification and remaining email/account-provisioning limits. The original tracker is preserved under `/tracker/`.

**Registration is live:** Open https://15.252.37.89/#/distributor/register or select “New distributor? Create an account” on the public login screen. Complete your profile, email/mobile and password; sign in with your registered email or mobile number and password; select “Continue to sign in.” The email is filled into the login form automatically on the same browser. The Distributor ID remains an account reference, not a sign-in credential. Recovery email delivery is still not configured.

## Review locally

```powershell
cd "F:\Arajpur East PDS\saas\flutter_client"
flutter pub get
flutter run -d chrome --dart-define=PDS_DEMO=true
```

For a compiled local preview:

```powershell
flutter build web --dart-define=PDS_DEMO=true
node preview.cjs
```

Open http://127.0.0.1:8090/#/distributor/login or http://127.0.0.1:8090/#/super-admin/login.

| Preview account | ID | Password |
| --- | --- | --- |
| Super Admin | admin@pds.demo or ADMIN-001 | Preview@12345 |
| Distributor A | distributor1@pds.demo or 9876543210 | Preview@12345 |
| Distributor B | distributor2@pds.demo or 9876543211 | Preview@12345 |

These are deliberately public test fixtures, not real accounts. Demo mode is opt-in at build time, displays explicit labels, sends no recovery emails, has no backend connection, and never persists an authenticated session. Remember Me stores the login ID in this preview. Without PDS_DEMO or a configured API, login fails with a clear configuration message rather than granting access.

## What works

- Separate login pages, field validation, show/hide password, loading/error feedback, Remember Me and recovery requests.
- GoRouter URL/deep-link handling and role guards, anonymous access denial, unauthorized screen, logout and session expiry/resume checks.
- Desktop split login layout and dashboard sidebar; scrollable tablet/phone forms, mobile drawer, SafeArea, 48px minimum controls.
- Two distinct dashboard shells with planned modules visibly disabled and no invented business totals.
- Session-derived Distributor ID scope, tenant-specific cache keys and defensive record filtering. Super Admin cannot construct a business-data scope.
- API repository with HTTPS validation, timeout/network errors, role/identity response checks, secure native refresh-token persistence and web HttpOnly-cookie support. Serialized persistence prevents cancelled login responses from restoring a logged-out session.

## Architecture

```text
lib/
  main.dart                 Build-time API/demo dependency selection
  app.dart                  Router, route guards, theme, lifecycle
  auth/
    models.dart             Two roles, validated session, distributor scope
    repository.dart         Authentication interface
    controller.dart         Observable state, login/logout/expiry
    api_repository.dart     Future API integration and persistence
    demo_repository.dart    Explicit development fixtures
    platform_session.dart   Conditional platform adapter
    platform_session_native.dart
    platform_session_web.dart
  ui/
    theme.dart              Shared branding and accessible controls
    login_page.dart         Role-specific login/recovery screens
    dashboard_page.dart     Responsive dashboard shells
test/                       Auth, API-contract and responsive tests
android/ ios/ web/          Generated platform projects
```

## Backend connection

Use `--dart-define=PDS_API_URL=https://15.252.37.89/api/v1` and omit `PDS_DEMO` for AWS. Follow [API_CONTRACT.md](API_CONTRACT.md). NestJS now exposes the two-login contract and has been verified against the private AWS PostgreSQL database. Email recovery and real distributor enrollment remain to be configured. Web clients must be served from the API's allowed HTTPS origin; a localhost build needs a corresponding local API/origin configuration. Database isolation is enforced server-side using authenticated identity and PostgreSQL RLS.

## Android review APK

```powershell
flutter build apk --debug --dart-define=PDS_DEMO=true
```

Output: `build/app/outputs/flutter-apk/app-debug.apk`. The demo APK is for review only. A production release requires the actual API plus your own `android/key.properties` (storeFile, storePassword, keyAlias, keyPassword) and signing keystore. Release builds deliberately refuse to use debug signing. Signing files are ignored by Git.

iOS source is included. Building/signing iOS requires macOS, Xcode and your Apple signing setup; it cannot be validated on this Windows workstation.

## Validation

```powershell
flutter analyze
flutter test
flutter build web --dart-define=PDS_DEMO=true
```

Tests cover login success/failure, role routing, logout/cancelled login, tenant filtering/admin scope denial, API HTTPS and role checks, recovery feedback and both login/dashboard layouts at 320, 768 and 1440 pixels. No real backend or real-device iOS verification has been performed.
