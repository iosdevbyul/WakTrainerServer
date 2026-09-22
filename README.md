# WakTrainerServer

The backend foundation for the WakTrainer app, built with Swift 6.3, Vapor 4,
Fluent, and PostgreSQL 16. Protected requests validate their current session over
HTTP with the separate TrisAuthenticationServer. WakTrainer domain APIs are not
implemented yet.

## Local development

Requires Swift 6.3 or later and Docker Compose v2.

```sh
cp .env.example .env
# Change DATABASE_PASSWORD in .env to a local development password.
docker compose up -d db
swift build
swift run WakTrainerServer serve --hostname 127.0.0.1 --port 8081
```

Run commands from the repository root so Vapor can load `.env`. The example uses
PostgreSQL host port 5433 and HTTP port 8081 to reduce conflicts with the separate
authentication server.

```sh
curl --fail http://127.0.0.1:8081/health
# {"status":"ok"}
```

`/health` is a liveness endpoint that returns JSON without authentication or a
database query. It does not guarantee database readiness. Fluent opens database
connections on demand, so application startup and database connectivity are
verified separately.

## Database configuration

| Variable | Default | Description |
| --- | --- | --- |
| PORT | 8080 | HTTP listening port; uses the value injected by Railway |
| DATABASE_URL | None | Takes precedence over individual database settings |
| DATABASE_HOST | Development: 127.0.0.1 | Must be explicitly set in production |
| DATABASE_PORT | 5432 | Database port; the example .env uses host mapping 5433 |
| DATABASE_USERNAME | Development: waktrainer | Must be explicitly set in production |
| DATABASE_PASSWORD | Required | Empty values are rejected |
| DATABASE_NAME | Development: waktrainer | Required in production; separate from the authentication database |
| DATABASE_TLS | See below | disable or require; also overrides URL TLS settings |

HTTP defaults to `0.0.0.0:$PORT`. Explicit `--hostname` and `--port` CLI options
override these settings. The Docker startup command does not hardcode a port.

`DATABASE_URL` accepts `postgres://` or `postgresql://` URLs with a username,
password, hostname, and database name. An invalid URL fails configuration instead
of falling back to local settings. Error messages do not include the URL or
password. Individual database variables apply only when `DATABASE_URL` is absent.

URLs can specify `sslmode` or `tlsmode`; the driver's URL default is `prefer`.
Individual database settings default to TLS `disable` in development/testing and
`require` in production. An explicit `DATABASE_TLS` overrides either mode.
`require` validates the server certificate.

Fluent registers PostgreSQL as the default database under `.psql`. No models or
migrations are registered yet. Compose creates a project-specific named volume;
it does not use the authentication server's volume. The Compose app connects to
the database container on its internal port 5432. For external deployments,
provide passwords through secret management and configure TLS appropriately.

## Read-only database diagnostic

After deploying an image containing this command, run it inside the
**WakTrainerServer application container**:

```sh
/app/WakTrainerServer verify-database --env production
echo $?
```

The command reuses the application's Fluent PostgreSQL configuration, including
`DATABASE_URL` and `DATABASE_TLS`. Normal production configuration requirements,
including `AUTHENTICATION_SERVER_URL`, still apply. It opens a real connection
from this invocation of the application binary without starting an HTTP server,
calling the authentication service, or running migrations.

The report requires database `waktrainer`, user `waktrainer_app`, active PostgreSQL
TLS, a read-only transaction, database CONNECT, and public schema USAGE. Exit code
0 means all checks passed; a failed check or connection returns exit code 1.
The current deployment should use `DATABASE_TLS=require`; disabling TLS makes
this diagnostic fail even if the connection succeeds.

Database CREATE, public schema CREATE, and elevated role privileges are reported
as observations, not required privileges or a least-privilege certification.
Elevated role means superuser, CREATEDB, CREATEROLE, replication, or BYPASSRLS.
No application tables exist yet, so this does not certify future table or sequence
permissions, schema readiness, or authentication-database isolation.

Only catalog queries and transaction-control statements run, inside
`BEGIN READ ONLY` with a five-second statement timeout and a final `ROLLBACK`.
Driver diagnostics are suppressed, and errors use fixed text without credentials
or connection URLs. Running this command on a Mac proves only that Mac's
connectivity. Running it in the deployed application container verifies that
container's network and application configuration, not an existing HTTP worker's
connection pool.

Diagnostic unit tests run with `swift test`. Optional PostgreSQL integration
coverage requires a disposable local TLS-enabled PostgreSQL instance with database
`waktrainer` and user `waktrainer_app`. Set the individual `DATABASE_*` fixture
variables, `RUN_DATABASE_DIAGNOSTIC_TESTS=1`, and `TEST_DATABASE_CA_FILE` to its
trusted certificate file, then run:

```sh
swift test --filter DatabaseDiagnostic
```

The fixture accepts only `localhost` or `127.0.0.1`, ignores `DATABASE_URL`, and
tests both TLS and plaintext connections. Test-only certificate trust preserves
certificate and hostname verification without changing system trust. It does not
provision the fixture or modify database data.


### Database diagnostic network policy

The `verify-database` command uses an explicit network policy to
evaluate the PostgreSQL TLS state.

`DATABASE_NETWORK` supports two values:

- `public` (default): Requires `DATABASE_TLS=require` and an
  active PostgreSQL TLS connection.
- `railway-private`: Allows PostgreSQL TLS to be disabled only
  when `DATABASE_URL` targets `postgres.railway.internal:5432`
  and `DATABASE_TLS=disable`.

Production configuration for Railway private networking:

```text
DATABASE_NETWORK=railway-private
DATABASE_TLS=disable
DATABASE_URL=postgresql://<user>:<password>@postgres.railway.internal:5432/waktrainer
```

For public database connections:

```text
DATABASE_NETWORK=public
DATABASE_TLS=require
```

The diagnostic always reports the actual PostgreSQL TLS state.
A private-network configuration can satisfy the diagnostic policy
without PostgreSQL TLS, but hostname and environment validation
do not independently prove that network traffic is encrypted.

Invalid or contradictory configurations are rejected.

## Authentication integration

Set `AUTHENTICATION_SERVER_URL` to the authentication server's base URL. Development
and tests default to `http://127.0.0.1:8080`; production requires an explicit value
and fails startup if it is missing. Use HTTPS for public endpoints, or an HTTP
address on a trusted private network. URLs may include a path prefix and trailing
slash, but must not include credentials, a query, or a fragment. No production URL
is hardcoded.

Each protected request with a valid bearer header makes
`GET {AUTHENTICATION_SERVER_URL}/auth/introspect`,
forwarding the original access token only in `Authorization: Bearer <access-token>`.
Other incoming headers, query parameters, and bodies are not forwarded. The client
uses a five-second timeout and refuses redirects. Responses are not cached.

A response authenticates the request only when HTTP 200 contains `active: true`
and valid UUIDs in both `userId` and `sessionId`. The middleware attaches a minimal
`AuthenticatedUser` to Vapor's request authentication storage. Handlers use
`try request.auth.require(AuthenticatedUser.self)` and do not call the authentication
server themselves.

| Condition | WakTrainer response |
| --- | --- |
| Missing, malformed, or duplicate bearer authorization | 401 |
| Upstream 401/403 or `active: false` | 401 |
| Invalid JSON/UUIDs, missing fields, unexpected status, or redirect | 502 |
| Upstream 5xx/429, timeout, or connection failure | 503 |

Errors use fixed messages; upstream bodies and transport details are not exposed.
Tokens are not logged or persisted. Only the authenticated user and session UUIDs
are retained for the current request.

`GET /v1/auth-test` is a temporary verification endpoint. Send the bearer header
and expect HTTP 200 with only:

```json
{
  "userId": "<user UUID>",
  "sessionId": "<session UUID>"
}
```

Future APIs can join the existing authenticated `/v1` group in `routes.swift`.
No domain routes are included now. `/health` remains public and makes neither a
database query nor an introspection request; it also works during an authentication
service outage once this server is configured and running.

## Tests

```sh
swift test
# After starting the database container, include the connection test:
RUN_DATABASE_TESTS=1 swift test
```

The default tests verify health, startup/shutdown, configuration, bearer forwarding,
UUID validation, middleware, failure mapping, and log/response redaction. They use
mock authentication clients plus a loopback HTTP redirect test; they never require
the deployed authentication server or a running database. The connection
test runs only with `RUN_DATABASE_TESTS=1` and fails if a connection cannot be
acquired. `.env` is for local use. Check the target database variables before
running integration tests. The current connection test does not modify data.

## Docker

```sh
AUTHENTICATION_SERVER_URL=http://host.docker.internal:8080 docker compose --profile app up --build -d
curl --fail http://127.0.0.1:8081/health
docker compose --profile app logs app
docker compose --profile app down
```

By default, `docker compose up -d` starts PostgreSQL only. The `app` profile also
starts the server. The image uses separate Swift build and Ubuntu runtime stages
and runs as a non-root user. `.env` is excluded from the image.

The example above uses Docker Desktop to reach an authentication server on the
host. Container loopback (`127.0.0.1`) refers to the container itself; choose an
authentication-server address reachable from the app container. On other Docker
setups, provide the appropriate host or service address. Compose passes
`AUTHENTICATION_SERVER_URL` into the production-mode app explicitly.

`down` preserves database data. Initial PostgreSQL user/password settings apply
only when an empty volume is initialized for the first time.

## CI and responsibility boundaries

GitHub Actions runs on pull requests and pushes to `main` or
`chore/bootstrap-server`, using a Swift 6.3 Linux container and a PostgreSQL 16
service. It resolves the locked dependencies in `Package.resolved`, runs
`swift build` and `swift test` with the database connection test enabled, then
verifies `DATABASE_URL` connectivity using the same test binary.

The separate shared TrisAuthenticationServer owns login, logout, registration,
token issuance/refresh, password reset, and session management. WakTrainerServer
validates sessions through its HTTP introspection endpoint. It never queries the
authentication database and has no dependency on AuthenticationKit or
AuthenticationServerKit.

There are no User database models, JWT signing/parsing, token refresh handling,
Workout/Routine/Exercise/Statistics/Calendar domains, caching, service API keys,
or dependencies on iOS model packages.

## Railway deployment preparation

No Railway project has been created or deployed as part of this phase.
Use the root of the independent WakTrainerServer repository as the deployment
source. Railway [automatically detects the Dockerfile](https://docs.railway.com/builds/dockerfiles).
`docker-compose.yml` is for local development and is not the Railway deployment
configuration.

### Service settings

| Setting | Value |
| --- | --- |
| Root Directory | Repository root `/` |
| Builder | Automatically detected `Dockerfile` |
| Custom Build Command | Leave empty |
| Custom Start Command | Leave empty; use Docker ENTRYPOINT/CMD |
| Healthcheck Path | `/health` |
| Healthcheck Timeout | Start with the default 300 seconds |
| Pre-deploy Command | Leave empty for Phase 1 |
| PORT | Use the Railway-injected value; no manual fixed port required |

Docker starts `serve --env production --hostname 0.0.0.0`, and the application
reads `PORT`. `EXPOSE 8080` documents the default port; it does not force the
listening port to 8080. Configure a domain in Railway Networking when HTTP access
is needed.

### Railway variables

For a PostgreSQL service named `Postgres` in the same Railway project and
environment, set the following variables on the application service. Adjust the
reference if the database service has a different name.

```text
DATABASE_URL=${{Postgres.DATABASE_URL}}
DATABASE_TLS=disable
LOG_LEVEL=info
AUTHENTICATION_SERVER_URL=https://authentication.example
```

Replace `https://authentication.example` with the reachable TrisAuthenticationServer
base URL. It must expose `/auth/introspect` using the existing bearer contract.
No shared authentication package or authentication database credentials are needed.

This `DATABASE_TLS=disable` example applies to an **internal database address on
Railway's private network**. [Railway private networking](https://docs.railway.com/networking/private-networking)
encrypts service-to-service traffic with WireGuard. Do not reuse this setting for
a public database address. For an external database, use a trusted server
certificate and `DATABASE_TLS=require`.

To preserve the URL's TLS settings, omit `DATABASE_TLS`. The driver validates
certificates whenever TLS is used, so the database certificate and hostname must
support that validation.

With `DATABASE_URL`, separate variables such as `DATABASE_PASSWORD` are not
required. Alternatively, configure individual variables:

```text
DATABASE_HOST=${{Postgres.PGHOST}}
DATABASE_PORT=${{Postgres.PGPORT}}
DATABASE_USERNAME=${{Postgres.PGUSER}}
DATABASE_PASSWORD=${{Postgres.PGPASSWORD}}
DATABASE_NAME=${{Postgres.PGDATABASE}}
DATABASE_TLS=disable
```

This example also assumes an internal database address. See the
[PostgreSQL connection variable documentation](https://docs.railway.com/databases/postgresql).
Do not upload `.env` to Railway. Store real passwords and connection URLs in
Railway Variables, not in the repository or Docker build arguments. The
repository contains only local/CI example values. Docker builds require neither
database connectivity nor secrets.

### Migration strategy

Phase 1 has no models or migrations, so leave the pre-deploy command empty.
Migrations do not run automatically during application startup or Docker builds.
When domain migrations are introduced, register them with
`app.migrations.add(...)` and configure the Railway Pre-deploy Command:

```sh
/app/WakTrainerServer migrate --yes --env production
```

Run it once before serving traffic using the same image, rather than on every
replica's startup. [Railway pre-deploy commands](https://docs.railway.com/deployments/pre-deploy-command)
can access environment variables and the private network; a failure prevents the
deployment from proceeding. Future migrations should remain compatible with the
previous application version, with database backups and a single migration
execution path.

### Health check semantics

`/health` returns HTTP 200 JSON without authentication or Host restrictions, so
it can serve as a [Railway health check](https://docs.railway.com/deployments/healthchecks).
It currently checks liveness only, not database connectivity or schema readiness.
Railway's deployment health check runs during deployment activation and is not
continuous monitoring. Decide whether to add a database readiness check when
domain functionality is introduced.
