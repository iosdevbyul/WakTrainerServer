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

## Validation

```sh
swift build
swift test
```

The default tests do not require a database. PostgreSQL integration tests run only when `TEST_DATABASE_NAME` is set. Its value must start with `waktrainer_test_`. Always use an empty, disposable database: the tests create tables and revert migrations at the end.

Optional settings: `TEST_DATABASE_HOST` (127.0.0.1), `TEST_DATABASE_PORT` (55439), `TEST_DATABASE_USERNAME` (postgres), and `TEST_DATABASE_PASSWORD`.

```sh
TEST_DATABASE_NAME=waktrainer_test_auth swift test
```

Integration tests cover signup, duplicate email handling, failed login, JWT authentication, a single successful concurrent refresh, rejection of tokens after logout, revocation of all sessions after a password change, and user and session deletion on account withdrawal.
