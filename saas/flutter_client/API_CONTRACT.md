# Two-role authentication API contract

This contract is now implemented by NestJS at https://15.252.37.89/api/v1 and connected to private PostgreSQL on Lightsail. The earlier email/mobile membership login has been replaced at the public login endpoints by exactly two login types. GitHub Pages remains a static website, not the authentication database. Role-specific recovery endpoints currently return 503 explicitly because delivery is not configured.

`PDS_API_URL` is an HTTPS base URL ending in `/api/v1`. Local development also accepts localhost, 127.0.0.1 and Android emulator host 10.0.2.2 over HTTP. Native platform transport policies may require development-only configuration for HTTP. Never enable cleartext globally in production.

## Endpoints

| Method and path | Request | Result |
| --- | --- | --- |
| POST auth/super-admin/login | identifier, password, rememberMe, clientType | Session |
| POST auth/distributor/login | identifier, password, rememberMe, clientType | Session |
| POST auth/distributor/register | email, mobile, password, confirmPassword, organization | distributorId and success message |
| POST auth/refresh | Native: refreshToken. Web: empty object plus cookie and X-CSRF-Token | Rotated session |
| POST auth/logout | Empty object; Authorization Bearer access token; web CSRF header | 200 or 204; revoke session and clear cookies |
| POST auth/super-admin/forgot-password | identifier | Generic 200 response |
| POST auth/distributor/forgot-password | identifier | Generic 200 response |

`clientType` is WEB or NATIVE. `identifier` is the distributor's assigned unique `DIST-` number, or the Super Admin email/Admin ID. IDs are assigned and constrained UNIQUE by the server, never created by the client. Exactly two roles are accepted. Do not add a role selector, staff account, or distributor-admin account.

## Session response

Public distributor registration accepts the existing organization fields plus email, international mobile, password and confirmation. Passwords require 12–128 characters. The server creates the user, unique sequence-generated Distributor ID, profile, membership and audit entry in one transaction. Only the DISTRIBUTOR role can be created. New isolated workspaces are ACTIVE immediately for sign-in; no subscription, contact verification, or licence verification is implied. Email/mobile verification timestamps remain null. This self-signup flow supersedes the earlier pending-verification registration path for the public app.

Retries with the same email, mobile and password return the assigned ID without changing the profile or password. Conflicting existing contacts return 409. The API rate-limits signup by IP and email. Registration does not send an OTP because delivery remains unconfigured. Super Admin signup is not exposed.

```json
{
  "userId": "server-user-uuid",
  "name": "Arajpur East PACS",
  "role": "DISTRIBUTOR",
  "distributorId": "DIST-000001",
  "accessToken": "server-issued-short-lived-bearer-token",
  "expiresAt": "2026-09-13T20:10:00Z",
  "refreshToken": "native-clients-only-opaque-rotating-token"
}
```

Super Admin sessions use `SUPER_ADMIN` and a null distributorId. Responses must not contain a user's other memberships or other distributors' private records. The sample above is a schema example, not a provisioned account or token.

Distributor responses also include `profile` with `distributorId`, `organizationName`, `address` and `phone`, selected from the authenticated session's distributor. The client rejects a profile belonging to a different distributor. Super Admin receives `profile: null`. Login and refresh return the current profile values for dashboard display.

The client rejects expired sessions, unsupported roles, missing distributor IDs, role mismatch, and identity changes during refresh. Send ISO 8601 UTC expiry values. Native responses must include an opaque refresh token. Web responses must omit that token and set it as `pds_refresh`, Secure, HttpOnly, SameSite=Strict, Path=/api/v1/auth. Also set `pds_csrf`, Secure, SameSite=Strict, Path=/, readable by the web app. Deploy web and API on the same origin using a reverse proxy so the CSRF cookie is readable. Validate Origin and CSRF on state-changing requests. Configure explicit CORS origins with credentials; never wildcard credentials.

Remember Me controls server session lifetime/cookie Max-Age and native secure persistence. Access tokens remain in memory. The browser stores only a non-sensitive remember flag and optional login ID; no passwords or bearer/refresh tokens in LocalStorage. Native refresh tokens are stored in platform secure storage only when Remember Me is selected. Unchecked sessions exist only for the current app process. Preview mode always uses memory-only sessions.

Refresh rotates tokens and revokes the token family on replay. Every authenticated server request must check session revocation, account activation/suspension, expiry and role. A logout network failure still clears this device's session, but the UI reports that remote revocation was not confirmed. The server must bound session duration independently of the client.

## Data isolation enforcement

Flutter route guards and `DistributorScope` are defense-in-depth, not a security boundary. A modified client can bypass UI checks. The backend must derive distributor identity from the validated session, map its public Distributor ID to the internal distributor UUID, and run PostgreSQL queries in that tenant's transaction-local RLS context. Never trust a tenant ID from a URL, header, or request body as authorization. Retain FORCE ROW LEVEL SECURITY and non-owner/NOBYPASSRLS database connections from the database foundation.

Super Admin endpoints may read distributor contact/profile and platform subscription/payment metadata only. They must have no beneficiary, stock, distribution, business transaction or business-report API. Do not provide a tenant impersonation endpoint. Test cross-tenant reads/writes and direct object IDs on the actual server before accepting real data.

Rate-limit login/recovery, hash passwords on the server, keep reset responses non-enumerating, issue single-use expiring recovery links, and provide server-side audit logging. The Flutter recovery screen requests delivery; the backend must implement the actual secure reset flow. No email is sent in demo mode.
