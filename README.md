# WakTrainerServer

**English** | [한국어](README.ko.md)

WakTrainerServer is an authentication backend built with Vapor, Swift 6.3, and PostgreSQL.

It currently supports:

- User registration
- Login and logout
- JWT access tokens
- Refresh-token rotation
- Current user lookup
- Active session listing and individual/other/all session logout
- Password changes
- Password reset by email
- Email ownership verification
- Email changes after verifying the new address
- Account deletion
- Login rate limiting
- Shared rate limiting for user-triggered email delivery
- PostgreSQL security audit logging

## Requirements

- Swift 6.3
- macOS 13 or later for local SwiftPM development, or the provided Linux Docker image
- PostgreSQL
- Resend credentials for actual email delivery

The local Docker Compose environment uses PostgreSQL 16.

The Dockerfile builds with `swift:6.3-noble`.

JWTKit is currently pinned to 5.6.0 because the warnings-as-errors configuration in 5.7.0 conflicts with Xcode dependency warning suppression.

See [Package.swift](Package.swift) and [Package.resolved](Package.resolved) for the currently resolved dependencies.

## Local setup

Configure the required values through process environment variables or a local `.env` file.

Do not commit secrets.

A JWT secret can be generated with:

```sh
openssl rand -base64 48
```

### Environment variables

| Variable | Requirement / default |
| --- | --- |
| `AUDIT_HASH_KEY` | Separate HMAC-SHA256 key for audit identifiers; missing key omits hash fields only |
| `JWT_SECRET` | Required |
| `DATABASE_PASSWORD` | Required |
| `DATABASE_HOST` | Defaults to `127.0.0.1` |
| `DATABASE_PORT` | Defaults to `5432` |
| `DATABASE_USERNAME` | Defaults to `vapor` |
| `DATABASE_NAME` | Defaults to `waktrainer` |
| `RESEND_API_KEY` | Required for actual email delivery |
| `PASSWORD_RESET_URL_BASE` | Base URL used for password-reset links |
| `EMAIL_CHANGE_URL_BASE` | HTTPS frontend URL for email-change confirmation |
| `EMAIL_VERIFICATION_URL_BASE` | HTTPS frontend URL for email-verification links |
| `EMAIL_TRUST_RAILWAY_PROXY` | Enables trusted Railway `X-Real-IP` handling when set to `true` |

Example frontend destinations:

```text
https://your-frontend.example/reset-password
https://your-frontend.example/verify-email
https://your-frontend.example/change-email
```

The password-reset URL should currently be configured without an existing query string or fragment because the server appends the reset token to the configured base URL.

Email-verification and email-change URLs must use HTTPS with a host and no URL username/password.
Their existing query parameters are preserved, with any `token` parameter replaced.
These destinations must provide the frontend/app confirmation flow; the server provides the POST APIs and email templates.

## Running locally

Start PostgreSQL:

```sh
docker compose up -d db
```

Apply migrations:

```sh
swift run WakTrainerServer migrate --yes
```

Start the server:

```sh
swift run WakTrainerServer serve --hostname 127.0.0.1 --port 8080
```

Changing `DATABASE_PASSWORD` in `.env` does not automatically update credentials stored in an existing PostgreSQL Docker volume.

The Dockerfile and Docker Compose startup configuration do not automatically run database migrations.

## Email delivery

Email delivery is implemented through the `EmailSending` abstraction and the Resend provider.

User-triggered email flows pass through the shared email rate limiter before delivery.

Currently supported email flows include:

- Password reset
- Email verification
- Email verification resend
- Email-change verification

The development sender currently uses Resend's onboarding sender. Configure a verified sender and domain before using a production mail identity.

## Database migrations

Apply all pending migrations before starting an updated server.

The current migration registration order is:

1. `CreateUserMigration`
2. `CreateRefreshTokenMigration`
3. `CreateLoginRateLimitMigration`
4. `CreatePasswordResetTokenMigration`
5. `CreateEmailRateLimitMigration`
6. `AddEmailVerificationMigration`
7. `AddEmailChangeMigration`
8. `AddSessionMetadataMigration`
9. `IndexSessionUserExpiryMigration`
10. `CreateAuditLogMigration`

`AddEmailVerificationMigration` adds the user's email-verification state and the email-verification token table.

Existing users receive an initial unverified state but remain able to authenticate.

`AddEmailChangeMigration` adds a separate pending-token table. `AddSessionMetadataMigration`
adds nullable session metadata without rewriting existing session values; column changes use a
five-second lock timeout. `IndexSessionUserExpiryMigration` builds the per-user expiration index
concurrently and must run outside a transaction. The current Fluent migrator supports this.

Apply these migrations through the existing pre-deploy command. Upgrade every server instance before
using session management: older code does not carry the management ID forward during refresh.
See [session management deployment](docs/session-management.md#railway-migration) for retry and rollback details.

Tests use a separate PostgreSQL database and do not migrate the development database.

## Authentication API

Use:

```http
Content-Type: application/json
```

Protected endpoints use:

```http
Authorization: Bearer <accessToken>
```

### Endpoints

| Method | Path | Description |
| --- | --- | --- |
| POST | `/auth/signup` | Create a user and issue a session |
| POST | `/auth/login` | Authenticate and issue a session |
| POST | `/auth/refresh` | Rotate the refresh token and session |
| GET | `/auth/me` | Return the authenticated user |
| POST | `/auth/logout` | Revoke the current session |
| GET | `/auth/sessions` | List your active sessions |
| DELETE | `/auth/sessions/:sessionID` | Revoke your session by stable management ID |
| POST | `/auth/logout-other-sessions` | Revoke every session except the current one |
| POST | `/auth/logout-all` | Revoke all sessions, including the current one |
| POST | `/auth/change-password` | Change the password and revoke sessions |
| DELETE | `/auth/withdraw` | Delete the user account |
| POST | `/auth/forgot-password` | Request a password-reset email |
| POST | `/auth/reset-password` | Reset the password using a reset token |
| POST | `/auth/verify-email` | Verify email ownership using a verification token |
| POST | `/auth/resend-verification-email` | Request another verification email |
| POST | `/auth/request-email-change` | Request verification of a new email (Bearer + current password) |
| POST | `/auth/confirm-email-change` | Confirm the change (same-user Bearer + token) |

Email changes require the current password and Bearer authentication to request, then a mail token
and a valid Bearer session of the same user to confirm. Only the confirming session is retained.
The account email stays unchanged until confirmation. `AddEmailChangeMigration` adds a separate
token table without modifying existing data. See [email changes](docs/email-change.md) for API,
deployment, and token policies.

Session management requires Bearer authentication. Optional `X-Device-Name` on signup/login is display metadata, not authentication.
Management IDs survive refresh while JWT sid still rotates. `createdAt` is the current row creation time,
`startedAt` is the login start, and `lastRefreshedAt` is the latest successful refresh.
Existing authentication responses remain unchanged. See [session management](docs/session-management.md) for APIs, cleanup, and deployment details.

### Session response

Signup, login, and refresh return the same session structure:

```json
{
  "user": {
    "id": "<user UUID>",
    "email": "user@example.com",
    "isEmailVerified": false
  },
  "accessToken": "<JWT>",
  "refreshToken": "<opaque token>"
}
```

Other successful mutation endpoints generally return:

```json
{
  "message": "..."
}
```

Errors use Vapor's standard error response format.

Some API messages are currently Korean. The README language does not affect API response language.

## Input rules

Passwords must contain:

- 7 to 20 characters
- No more than 72 UTF-8 bytes

Email validation currently checks:

- Maximum 254 UTF-8 bytes
- Presence of `@`
- Presence of `.`

Duplicate email registration returns HTTP `409`.

Signup, login, and email changes compare/store email strings exactly as supplied; they do not trim or lowercase them.
Rate limiting separately trims and lowercases email addresses to group abuse counters.

## Sessions

Access tokens:

- JWT-based
- Expire after approximately 15 minutes
- Include `sub`, `exp`, and `sid`
- Require a valid backing database session

Refresh tokens:

- Use 32 random bytes
- Are encoded as 64 hexadecimal characters
- Are stored only as SHA-256 hashes
- Expire after approximately 30 days
- Are rotated after successful refresh

After refresh, clients must replace both the access token and refresh token.

Concurrent refresh requests using the same refresh token allow only one successful consumer.

Logout revokes only the current session.

Password change and password reset revoke all sessions and cancel pending email changes.
Email-change confirmation retains only the confirming session and marks the new address verified.
`logout-other-sessions` retains only the caller's current session; `logout-all` revokes it as well.

JWTs without a valid session identifier are not accepted.

### Managing sessions

`GET /auth/sessions` returns only the authenticated user's unexpired sessions:

```json
{
  "sessions": [
    {
      "id": "<stable management UUID>",
      "createdAt": "2026-09-09T09:00:00Z",
      "startedAt": "2026-09-09T08:00:00Z",
      "expiresAt": "2026-10-09T09:00:00Z",
      "lastRefreshedAt": "2026-09-09T09:00:00Z",
      "isCurrent": true,
      "deviceName": "My iPhone"
    }
  ]
}
```

`createdAt` describes the current refresh row; `startedAt` survives rotation; `lastRefreshedAt`
records successful refresh only, not every API request. Dates use second-precision ISO-8601.
Optional fields are omitted when unavailable. Legacy sessions use the oldest retained row's creation
time as their initial `startedAt`, which may differ from the original login time.

Use the returned management `id`, not JWT `sid`, with `DELETE /auth/sessions/:sessionID`.
Deleting the current session is allowed. Foreign and nonexistent IDs return the same `404`;
malformed UUIDs return `400`. Successful deletions return a `message` response.
The deleted session's access and refresh tokens fail subsequent validation.

`X-Device-Name` is optional on signup/login: one header, at most 128 UTF-8 bytes, no control characters.
Surrounding whitespace is trimmed; invalid or missing names are ignored. Refresh preserves the stored name.
No clientId, IP, or User-Agent session metadata is stored. Token values and hashes are never returned in this list.

Refresh and revocation use the same per-user database lock. A management ID continues to identify
a rotated successor, so revocation cannot miss it merely because the target refreshed first.
If the caller itself refreshes first, its old Bearer token is invalid and the management request may
return `401`; retry with the newly issued Bearer token.

Session issuance and listing lazily remove up to 100 expired rows belonging to that user.
All expired rows are excluded from the active list, even when cleanup leaves a backlog.
Global expired-row cleanup is available through the separate [maintenance command](docs/database-maintenance.md); existing lazy cleanup remains.

### Email verification state

Unverified users can still:

- Sign up
- Log in
- Refresh sessions
- Use the normal authenticated session flow

Email verification does not create or revoke sessions.

Clients can call:

```http
GET /auth/me
```

to refresh the user's `isEmailVerified` state.

Future features that require verified ownership should validate the user's verification state on the server.

## Password reset

Password-reset tokens:

- Use 32 random bytes
- Are stored only as SHA-256 hashes
- Expire after approximately 30 minutes
- Are single-use
- Are replaced when a new reset token is issued

A successful reset:

- Updates the password
- Removes outstanding reset tokens
- Cancels pending email changes
- Revokes all sessions

Unknown accounts and rate-limited forgot-password requests use the same successful outward response to reduce account-enumeration risk.

A generic success response does not guarantee inbox delivery.

## Email verification

Email-verification tokens:

- Use 32 random bytes
- Are stored only as SHA-256 hashes
- Expire after approximately 24 hours
- Are single-use
- Are replaced when a new verification token is successfully issued

Verification is performed through:

```http
POST /auth/verify-email
```

This endpoint does not require an authenticated session.

Successful verification sets:

```text
isEmailVerified = true
```

Invalid, expired, replaced, reused, or otherwise unusable verification tokens are rejected.

Verification email resend uses:

```http
POST /auth/resend-verification-email
```

The outward response intentionally does not reveal whether:

- The account exists
- The account is already verified
- The request was rate limited
- Delivery was suppressed

This reduces account-enumeration risk.

Configure `EMAIL_VERIFICATION_URL_BASE` as an HTTPS frontend URL, for example:

```text
https://your-frontend.example/verify-email
```

The server adds the token query parameter. The frontend can hand off to the app or use Universal Links,
then submit the token through POST. A custom URL scheme such as `waktrainer://` is not accepted as the configured base.
Opening a GET link alone does not verify the address.

Signup remains successful if verification delivery fails. Resend returns a generic successful message
even if delivery fails. Users can request another verification email.

## Email changes

Request a change with Bearer authentication:

```http
POST /auth/request-email-change
```

```json
{"currentPassword":"<current password>","newEmail":"new@example.com"}
```

The account email and verification state remain unchanged while pending. The current password must match.
An unchanged email returns `400`, an already-used address returns `409`, and throttling returns `429`.
The common email gateway consumes the `emailChangeVerification` action before token preparation.

Complete the change with a valid Bearer session of the same user, which may differ from the requesting session:

```http
POST /auth/confirm-email-change
```

```json
{"token":"<token from the email link>"}
```

Change tokens use 32 random bytes, SHA-256 storage, a 30-minute lifetime, and single-use consumption.
Issuing a new token invalidates the previous one. Delivery failure removes only that request's token;
the previous token is not restored, and the user can request another email.

Confirmation rechecks email uniqueness, changes the address, sets `isEmailVerified = true`, and
retains only the confirming session. It also deletes the change token and outstanding email-verification
and password-reset tokens. `/auth/me` and subsequent refresh responses reflect the new email.
Invalid, expired, reused, or foreign-user tokens return `400`; an email claimed before confirmation returns `409`.
Successful request/confirmation responses use the existing `message` format.

See [email changes](docs/email-change.md) for failure recovery and concurrency details.

## Rate limiting

### Login

Login attempts use PostgreSQL-backed counters.

Current policy:

- 30 attempts per IP per minute
- 10 attempts per email per 15 minutes

Both successful and failed attempts count toward the limit.

Exceeded limits return HTTP `429`.

### User-triggered email delivery

Email requests use a shared PostgreSQL-backed limiter.

The limiter combines several abuse signals:

- Recipient email
- Client ID
- IP address
- Email action
- Global send volume

Recipient, client, IP, and action identifiers used for limiter storage are SHA-256 hashed; the global bucket uses a fixed key.

`X-Client-ID` is optional and is treated only as an abuse-prevention signal, not as authentication.

Current detailed limits are documented in:

[docs/email-rate-limits.md](docs/email-rate-limits.md)

The server currently supports rate-limit actions including:

- `passwordReset`
- `signUpVerification`
- `emailChangeVerification`

### Railway proxy handling

By default, email rate limiting uses the directly connected IP address.

When:

```text
EMAIL_TRUST_RAILWAY_PROXY=true
```

the server may use a validated Railway `X-Real-IP` value for email rate limiting.

Enable this only when the deployment topology guarantees that requests originate through the trusted Railway edge.

Arbitrary `X-Forwarded-For` values are not trusted.

## Security audit logging

Major authentication, session, password, email, withdrawal, and rate-limit events are written to a separate
`audit_logs` table. See [audit logging](docs/audit-logging.md) for event semantics. No audit-query API is exposed.

Writes are best-effort after business transaction success. Audit storage failures do not change authentication
responses. Overload, timeouts, and process termination can cause missing events; delivery is not guaranteed.
A separate audit connection pool and short database timeouts limit impact on the authentication pool.

Email/IP/clientId values use HMAC-SHA256 with a separate AUDIT_HASH_KEY; raw values are not stored.
Without the key, hash fields are omitted while events are still recorded. Hashes remain pseudonymous identifiers.
Credentials, tokens, token hashes, secrets, device names, User-Agent, request bodies, and raw errors are excluded.
Metadata accepts only predefined enum and numeric fields.

Login/refresh failures, rate-limit blocks, and anonymous mail requests are deduplicated by event type,
identifier hashes, action (for email limits), and minute bucket. Different sources are not merged into one global event;
these records are samples rather than exact request counts. Withdrawal preserves history with user_id set to null.

Audit retention defaults to 90 days and is enforced when the maintenance command runs. See [audit logging](docs/audit-logging.md) for operator queries and privacy policy.

## Testing

Run:

```sh
swift build
swift test --disable-sandbox
```

The PostgreSQL integration test suite requires a disposable database named exactly:

```text
waktrainer_test_auth
```

Set:

```text
TEST_DATABASE_NAME=waktrainer_test_auth
```

and configure the corresponding test database connection values:

- `TEST_DATABASE_HOST`
- `TEST_DATABASE_PORT`
- `TEST_DATABASE_USERNAME`
- `TEST_DATABASE_PASSWORD`

The local Docker Compose setup creates only the development `waktrainer` database, so the integration-test database must be provisioned separately.

The integration suite uses:

- Mock email delivery
- Real PostgreSQL
- Real migrations

Missing or unsafe test database configuration causes the tests to fail rather than silently skip.

Do not run multiple integration or E2E suites concurrently against the same disposable test database.

Current coverage includes:

- Signup
- Login
- Refresh rotation
- Logout
- Account withdrawal
- Password changes
- Password reset
- Login rate limiting
- Shared email rate limiting
- Email verification and verified email changes
- Session ownership, current-session identification, metadata, and revocation
- Refresh/revocation races and per-user expired-session cleanup
- Token expiration
- Single-use token behavior
- Concurrent token consumption
- Account-enumeration-safe responses
- Migration upgrade/revert and preservation of existing users and sessions

Mock delivery tests do not verify actual inbox delivery.

## Production deployment

WakTrainerServer is currently deployed on Railway.

Current production architecture:

- Application hosting: Railway
- Database: Railway PostgreSQL
- Public API traffic: Railway HTTPS domain
- Secret management: Railway environment variables
- Email provider: Resend
- Database connection: Railway private network

Production migrations run as a Railway pre-deploy command:

```sh
./WakTrainerServer migrate --env production --yes
```

The application currently connects to Railway PostgreSQL over the private network with PostgreSQL TLS disabled at the application layer.

Production requires the relevant environment variables, including:

```text
JWT_SECRET
DATABASE_HOST
DATABASE_PORT
DATABASE_USERNAME
DATABASE_PASSWORD
DATABASE_NAME
RESEND_API_KEY
PASSWORD_RESET_URL_BASE
EMAIL_VERIFICATION_URL_BASE
EMAIL_CHANGE_URL_BASE
AUDIT_HASH_KEY
```

`AUDIT_HASH_KEY` is optional. Configure a separate key in production; without it, audit events are still recorded but identifier hash fields are omitted.

`EMAIL_TRUST_RAILWAY_PROXY` should only be enabled after validating the trusted proxy configuration.

Operational monitoring, production sender/domain configuration, backup strategy, and broader API-wide abuse protection should be reviewed as the service grows.

## Documentation

Additional documentation:

- [Security audit logging](docs/audit-logging.md)
- [Session management](docs/session-management.md)
- [Email changes](docs/email-change.md)
- [Email verification](docs/email-verification.md)
- [Shared email rate limiting](docs/email-rate-limits.md)
- [AuthenticationKit Demo E2E guide](docs/authentication-e2e.md)

## Database Maintenance

Run `./WakTrainerServer maintenance --env production` in a separate Railway Cron service with
schedule `0 * * * *` (hourly UTC), after the web service applies migrations. The same binary cleans
expired session/token/rate-limit rows and old audit logs in batches of 500, at most 20 batches per
table. `AUDIT_RETENTION_DAYS` defaults to 90; values below 90 are rejected. Existing lazy cleanup
remains. Any target failure produces a failure exit after the other targets are attempted.
See [database maintenance](docs/database-maintenance.md) for deployment, concurrency, limits and logs.

## API Error Responses

Errors retain `error` and `reason` and add `status`, `code`, `message`, and optional safe validation
`details`. `status` always equals the HTTP status, and `reason` always equals `message`. New clients
should branch on `code` and display `message`; `reason` is a compatibility field. Existing success
responses and HTTP status policies are unchanged. Internal diagnostic details are never copied into
error responses. See [API errors](docs/api-errors.md) for all codes, exceptions and client follow-up.
