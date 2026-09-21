# WakTrainerServer

The initial backend foundation for the WakTrainer app, built with Swift 6.3,
Vapor 4, Fluent, and PostgreSQL 16. Authentication and workout domains are outside
this phase.

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

## Tests

```sh
swift test
# After starting the database container, include the connection test:
RUN_DATABASE_TESTS=1 swift test
```

The default tests verify health responses, application startup/shutdown, and
configuration validation without requiring a running database. The connection
test runs only with `RUN_DATABASE_TESTS=1` and fails if a connection cannot be
acquired. `.env` is for local use. Check the target database variables before
running integration tests. The current connection test does not modify data.

## Docker

```sh
docker compose --profile app up --build -d
curl --fail http://127.0.0.1:8081/health
docker compose --profile app logs app
docker compose --profile app down
```

By default, `docker compose up -d` starts PostgreSQL only. The `app` profile also
starts the server. The image uses separate Swift build and Ubuntu runtime stages
and runs as a non-root user. `.env` is excluded from the image.

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
will eventually validate issued access tokens to identify users, but this phase
does not implement that integration.

There are no User database models, JWT logic, Workout/Routine/Exercise/Statistics
domains, or dependencies on iOS model packages.

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
```

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
