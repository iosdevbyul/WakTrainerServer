# WakTrainerServer

[한국어](README.md) | **English**

An authentication server built with Vapor, Swift 6.3, and PostgreSQL.

## Build environment

Development targets Swift 6.3 and macOS 13 or later. The resolved JWT packages are `vapor/jwt 5.1.2` and `jwt-kit 5.6.0`. JWTKit is pinned to 5.6.0 because version 5.7.0's warnings-as-errors setting conflicts with Xcode's warning suppression for external packages.

## Local setup

Set the required environment variables `JWT_SECRET` and `DATABASE_PASSWORD`. Never commit secret values to Git.
Generate a JWT secret with `openssl rand -base64 48`.
Set `DATABASE_PASSWORD` to the password already configured for your PostgreSQL database.
Changing the environment variable does not change the database password stored in an existing Docker volume.

Optional environment variables:

| Variable | Default |
| --- | --- |
| DATABASE_HOST | 127.0.0.1 (`db` for the Docker app service) |
| DATABASE_PORT | 5432 |
| DATABASE_USERNAME | vapor |
| DATABASE_NAME | waktrainer |

Run these commands from the terminal where the environment variables are set:

```sh
docker compose up -d db
swift run WakTrainerServer migrate --yes
swift run WakTrainerServer serve --hostname 127.0.0.1 --port 8080
```

The session implementation adds `CreateRefreshTokenMigration`. Apply migrations to your development database before starting the server. Tests use a separate database and do not automatically migrate your development database.

## Authentication API

Use `Content-Type: application/json` for JSON requests.
For authenticated requests, include `Authorization: Bearer <accessToken>`.

| Method / path | Request | Behavior |
| --- | --- | --- |
| POST /auth/signup | email, password | Create a user and issue tokens |
| POST /auth/login | email, password | Verify the password and issue tokens |
| POST /auth/refresh | refreshToken | Revoke the previous session and issue a new token pair |
| GET /auth/me | Bearer | Return the user's id and email |
| POST /auth/logout | Bearer | Revoke the current session |
| POST /auth/change-password | Bearer + currentPassword, newPassword | Change the password and revoke all sessions |
| DELETE /auth/withdraw | Bearer | Delete the user and all sessions |
| POST /auth/forgot-password | email | Return 503 because email delivery is not configured |

Access tokens are JWTs that expire after 15 minutes and contain `sub`, `exp`, and `sid`.
Refresh tokens are 32-byte opaque tokens generated using system randomness and encoded as 64 hexadecimal characters. Only their SHA-256 hashes are stored in the database. Each new refresh token expires 30 days after issuance.

After a successful refresh, clients must replace both tokens. Do not send parallel refresh requests with the same token. The access token associated with the previous refresh token becomes invalid immediately.
Logout revokes only the current session; other devices remain signed in.
Changing a password requires signing in again on every device.
Existing JWTs without `sid` and mock refresh tokens are no longer accepted. Sign in again to obtain a new session.

Password reset is not implemented yet. After choosing an email provider and sender address, email delivery, storage and verification of single-use reset tokens, and a reset-password endpoint must be implemented. The current endpoint returns 503 instead of claiming an email was sent.

## Login rate limiting

`POST /auth/login` shares request counters through PostgreSQL's `login_rate_limits` table. Apply `CreateLoginRateLimitMigration` before starting the updated server.

- Allow 30 attempts per directly connected IP in 60 seconds and 10 attempts per email in 15 minutes.
- Count both successful and failed attempts; success does not reset counters. Apply the IP limit before JSON decoding, and the email limit after input validation but before account lookup and bcrypt verification.
- Return `429 Too Many Requests` with `Retry-After` in seconds when exceeded. Attempts resume after the fixed window expires; rejected requests do not extend it.
- Trim whitespace and lowercase email addresses only for rate-limit keys. Account storage and login lookup remain case-sensitive.
- Store SHA-256 hashes instead of raw IP/email values. These hashes are still guessable by hashing candidate values and must not be treated as anonymous data.
- Use an atomic database upsert and database time to share limits across concurrent requests and application instances. Database errors do not bypass throttling.
- Clean up at most 100 expired entries per login request.

Forwarding headers such as `X-Forwarded-For` are not trusted. Behind a proxy, requests share that proxy's IP quota until a trusted-proxy and client-IP policy is implemented. Requests with no available IP share a common quota.

These limits are an initial policy. An attacker can temporarily exhaust another email's login quota, so monitor usage and throttling metrics when tuning them. Limits for other endpoints, such as signup and token refresh, and infrastructure-level traffic protection remain separate work. Reference: [OWASP Login Throttling](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html#login-throttling).

## Remaining work before public deployment

The current Docker Compose configuration and PostgreSQL `tls: .disable` setting target local development. Production readiness still requires:

- HTTPS termination and certificate renewal, trusted proxies, and a client-IP policy
- Production PostgreSQL TLS with server certificate/hostname verification and restricted database network access
- Secret injection through a secret manager or deployment environment, plus secret rotation
- Logging that excludes passwords/tokens and monitoring/alerts for errors, login failures, and 429 responses
- Stronger email validation, a lowercase/whitespace policy, and migration after checking existing account collisions
- Revisiting the JWTKit 5.6.0 pin after Swift/Xcode/JWT updates, with Xcode/CLI builds and authentication regression tests
- Password reset email delivery and single-use reset tokens

## Validation

```sh
swift build
swift test
```

The basic tests do not require a database. `swift test` also runs PostgreSQL integration tests. After the application loads `.env`, the tests require `TEST_DATABASE_NAME` to equal `waktrainer_test_auth`; missing or unsafe configuration fails instead of skipping. The development database `waktrainer` is never used. Use a dedicated test database: tests create tables and revert migrations on successful completion.

Optional settings: `TEST_DATABASE_HOST` (127.0.0.1), `TEST_DATABASE_PORT` (5432), `TEST_DATABASE_USERNAME` (vapor), and `TEST_DATABASE_PASSWORD`.

```sh
# Configure TEST_DATABASE_NAME and TEST_DATABASE_* connection settings in .env first
swift test
```

Integration tests cover signup, duplicate email handling, failed login, JWT authentication, a single successful concurrent refresh, rejection of tokens after logout, revocation of all sessions after a password change, and user and session deletion on account withdrawal.

Password reset integration coverage uses mock email delivery and real PostgreSQL to verify token creation, successful resets, rejection of used and expired tokens, rejection of the old password, login with the new password, and revocation of existing sessions.
