# WakTrainerServer

**English** | [한국어](README.ko.md)

WakTrainerServer is an authentication backend built with Vapor, Swift 6.3, and PostgreSQL.

It currently supports:

- User registration
- Login and logout
- JWT access tokens
- Refresh-token rotation
- Current user lookup
- Password changes
- Password reset by email
- Email ownership verification
- Email changes after verifying the new address
- Account deletion
- Login rate limiting
- Shared rate limiting for user-triggered email delivery

## Requirements

- Swift 6.3
- macOS 13 or later
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
| `JWT_SECRET` | Required |
| `DATABASE_PASSWORD` | Required |
| `DATABASE_HOST` | Defaults to `127.0.0.1` |
| `DATABASE_PORT` | Defaults to `5432` |
| `DATABASE_USERNAME` | Defaults to `vapor` |
| `DATABASE_NAME` | Defaults to `waktrainer` |
| `RESEND_API_KEY` | Required for actual email delivery |
| `PASSWORD_RESET_URL_BASE` | Base URL used for password-reset links |
| `EMAIL_CHANGE_URL_BASE` | HTTPS frontend URL for email-change confirmation |
| `EMAIL_VERIFICATION_URL_BASE` | Base URL used for email-verification links |
| `EMAIL_TRUST_RAILWAY_PROXY` | Enables trusted Railway `X-Real-IP` handling when set to `true` |

Example frontend destinations:

```text
https://your-frontend.example/reset-password
https://your-frontend.example/verify-email
https://your-frontend.example/change-email
```

The password-reset URL should currently be configured without an existing query string or fragment because the server appends the reset token to the configured base URL.

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

`AddEmailVerificationMigration` adds the user's email-verification state and the email-verification token table.

Existing users receive an initial unverified state but remain able to authenticate.

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

Email normalization used by rate limiting is separate from account-storage behavior.

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

Password change and password reset revoke all active sessions.

JWTs without a valid session identifier are not accepted.

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
- Revokes all active sessions

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

Verification links should point to a frontend or application entry point that extracts the token and submits it to the verification endpoint.

For example:

```text
waktrainer://verify-email?token=...
```

A production HTTPS frontend may also hand off to the app or use Universal Links.

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

Identifiers used for limiter storage are SHA-256 hashed.

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

## Testing

Run:

```sh
swift build
swift test
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
- Email verification
- Token expiration
- Single-use token behavior
- Concurrent token consumption
- Account-enumeration-safe responses
- Migration behavior for existing users

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
```

`EMAIL_TRUST_RAILWAY_PROXY` should only be enabled after validating the trusted proxy configuration.

Operational monitoring, production sender/domain configuration, backup strategy, and broader API-wide abuse protection should be reviewed as the service grows.

## Documentation

Additional documentation:

- [Email verification](docs/email-verification.md)
- [Shared email rate limiting](docs/email-rate-limits.md)
- [AuthenticationKit Demo E2E guide](docs/authentication-e2e.md)
