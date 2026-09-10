# Database Maintenance

`DatabaseMaintenanceService` performs bounded runtime cleanup through the same executable's
`maintenance` command. It does not serve HTTP, change authentication responses, or emit security
audit events. Schema migration and runtime data deletion are separate operations.

## Deletion policy

| Table | Eligible rows |
| --- | --- |
| `refresh_tokens` | `expires_at <= cutoff` |
| `password_reset_tokens` | `expires_at <= cutoff` |
| `email_verification_tokens` | `expires_at <= cutoff` |
| `email_change_tokens` | `expires_at <= cutoff` |
| `login_rate_limits` | `expires_at <= cutoff` |
| `email_rate_limits` | `expires_at <= cutoff` |
| `audit_logs` | `occurred_at < cutoff - audit retention days` |

The command captures one cutoff timestamp at its start and reuses it for every target and batch.
Rows becoming eligible later wait until the next run. Keep host clocks synchronized; authentication
already uses application time for token validity, while rate limit windows use PostgreSQL time.

`AUDIT_RETENTION_DAYS` defaults to **90**, configured centrally in `MaintenancePolicy`.
Values below 90, non-integers, or above 365000 are rejected before cleanup starts. The upper bound
prevents invalid date arithmetic. Exactly-at-boundary audit rows are retained. Retention applies
uniformly regardless of event type or whether `user_id` is null. Hash key rotation is unrelated.

Consumed/superseded/invalidated tokens are already deleted by existing authentication transactions;
there are no separate used-token flags or Session table. User withdrawal still cascades token rows.
No user rows are deleted by maintenance. Management session IDs, startedAt and rotation stay unchanged.

Existing bounded lazy cleanup remains: session issuance/listing removes up to 100 expired rows per
user, and rate limit requests remove up to 100 expired buckets. Session lazy cleanup also skips
locked rows to avoid waiting behind maintenance. Existing password reset expiry cleanup remains.
These paths provide limited cleanup if Cron is unavailable; they do not invoke the global service.

## Batches and concurrency

Each target runs at most **20 batches of 500 rows**, in its own short transactions: at most 10000 rows
per target and 70000 total per run. There is no OFFSET pagination or unbounded retry.
Candidates are ordered by expiry then primary key (`bucket_key` for rate limits), locked with
`FOR UPDATE SKIP LOCKED`, and deleted in the same SQL statement. Audit ordering uses `occurred_at,id`.
Rows locked by another transaction are skipped; a locked or capped backlog waits for another run.
A short batch can therefore finish a target even if locked eligible rows remain.

Concurrent runs may process different rows safely; no distributed/advisory lock is needed.
Maintenance never takes the authentication user-row lock. Candidate locking protects against
concurrent rate-limit renewal: rows already being updated are skipped, and committed future
expirations fail eligibility. Active refresh proofs and new rotation rows are not eligible.
Row locks are still real locks: another writer targeting the same expired row can briefly wait for
a batch to commit. This is bounded, not a promise of zero database contention under every workload.

The command uses a separate database pool (one connection per event loop, one-second pool wait),
with transaction-local **2s statement timeout** and **100ms lock timeout**. SQL tracing/provider logs
are disabled for this database handle. Authentication connection settings are unchanged.

A failed target stops its remaining batches; later targets still run. Successfully committed earlier
batches remain deleted. There is no automatic retry within a run, including during a DB outage.
Any target failure results in a nonzero command exit after results are logged. A capped target is a
successful bounded run, not a failure. Monitor repeated caps and adjust the schedule or central policy.

## Manual execution

Apply schema migrations first, then run cleanup:

```sh
swift run WakTrainerServer migrate --yes
swift run WakTrainerServer maintenance
```

For the built production image:

```sh
./WakTrainerServer maintenance --env production
```

The existing `DATABASE_*` settings and `JWT_SECRET` remain required by common application configuration.
Email provider keys and `AUDIT_HASH_KEY` are not used by cleanup. Do not include credentials in command
arguments or logs. The maintenance command closes application/database resources on completion.

## Railway production

1. Keep the web service's existing pre-deploy command:
   `./WakTrainerServer migrate --env production --yes`.
2. Create a separate Cron service from the same repository/Docker image and private PostgreSQL network.
   Reuse the database variable references and required common configuration. Do not expose a public
   HTTP domain or configure a web health check for this service.
3. Set its **Start Command** to `./WakTrainerServer maintenance --env production`.
   This is Railway's full [Start Command override](https://docs.railway.com/deployments/start-command). For a direct `docker run` using this image's existing
   executable ENTRYPOINT, pass only `maintenance --env production` as the container arguments.
4. Set **Cron Schedule** to `0 * * * *` (hourly, UTC). Configure restart policy **Never** so failure is
   investigated or retried on the next scheduled run instead of causing immediate retry bursts.
5. Run schema migrations through the web deployment before enabling/deploying the Cron version that
   uses them. Do not add a second concurrent migration runner to the Cron service.

Railway expects the process to exit and skips a schedule if the previous run is still active.
Schedules are not guaranteed to start at an exact minute. See the
[Railway Cron documentation](https://docs.railway.com/cron-jobs).
This repository does not provision or enable a Railway Cron service automatically.

## Migration safety

`IndexMaintenanceExpiryMigration` adds `(expires_at,id)` indexes to refresh, password reset,
email verification and email change token tables. Existing rate-limit expiry and audit time indexes
are reused. The user-leading refresh index remains useful for lazy cleanup.

Builds and reverts use PostgreSQL `CONCURRENTLY`, outside a transaction. Interrupted invalid indexes
are removed and rebuilt on retry. Valid completed indexes are reused, including after a partially
completed migration. No rows are backfilled or deleted by this migration. Revert only drops the new
indexes. Concurrent builds still consume I/O, storage and WAL, and can wait for older transactions;
plan deployment capacity accordingly and avoid concurrent migration runners. Standard DELETE does
not immediately shrink the database files; PostgreSQL autovacuum reclaims reusable space. Monitor
backlogs and autovacuum rather than adding VACUUM FULL/TRUNCATE to this command.

## Results and verification

Structured application logs contain only `target`, `deleted`, `duration`, `status`, and `capped`.
Counts reflect committed deletes; no user IDs, email/IP, tokens, token hashes, secrets, request bodies
or database error text are logged. A failure exit is accompanied by a generic error message.
No HTTP results or audit-log records are created.

PostgreSQL tests cover expiry/retention boundaries, batch limits, concurrent cleanup, live refresh
rotation, locked and renewed rate-limit rows, table-lock timeout and independent-target failure,
as well as index upgrade/retry/revert and existing authentication regressions.
