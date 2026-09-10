# API errors

All errors reaching the Vapor application responder use the following JSON contract.
Successful responses, HTTP statuses, authentication transactions and token policies remain unchanged.

```json
{
  "error": true,
  "status": 401,
  "code": "INVALID_CREDENTIALS",
  "message": "이메일 또는 비밀번호가 올바르지 않습니다.",
  "reason": "이메일 또는 비밀번호가 올바르지 않습니다."
}
```

`error` and `reason` are compatibility fields. **New clients should use `code` and `message`, not
parse `reason` or message strings.** The middleware derives both the HTTP status and JSON `status`
from the same selected status. `reason` is always generated from `message`; call sites cannot set
these two strings independently. Optional `details` is omitted when unavailable.

Validation details contain only closed enum values, never submitted values or decoder diagnostics:

```json
{
  "error": true,
  "status": 400,
  "code": "VALIDATION_FAILED",
  "message": "올바른 이메일 형식을 입력해주세요.",
  "reason": "올바른 이메일 형식을 입력해주세요.",
  "details": [{ "field": "email", "code": "INVALID_FORMAT" }]
}
```

Current detail fields are `email`, `newEmail`, `sessionID`; detail codes are `INVALID_FORMAT` and
`MUST_DIFFER`. Compound password validation retains its existing public message without disclosing
which credential comparison failed. Validation rules and first-failure ordering are unchanged.

## Public codes

| Code | HTTP status | Meaning |
| --- | --- | --- |
| `INVALID_REQUEST` | 400 | Malformed JSON, missing/wrong-type input, untyped bad request |
| `VALIDATION_FAILED` | 400 | Existing input rules rejected the request |
| `INVALID_CREDENTIALS` | 401 | Email/password login rejected; no existence distinction |
| `CURRENT_PASSWORD_INVALID` | 401 | Current password verification failed |
| `AUTHENTICATION_REQUIRED` | 401 | Missing Bearer proof; also safe fallback for untyped 401 |
| `ACCESS_TOKEN_INVALID_OR_EXPIRED` | 401 | JWT verification/claims failed |
| `SESSION_INVALID` | 401 | Session missing, expired, revoked or mismatched; shared user-disappearance guard |
| `REFRESH_TOKEN_REJECTED` | 401 | Invalid, expired, consumed or revoked refresh proof |
| `PASSWORD_RESET_TOKEN_INVALID` | 400 | Invalid/expired/consumed reset proof |
| `EMAIL_VERIFICATION_TOKEN_INVALID` | 400 | Invalid/expired/consumed verification proof |
| `EMAIL_CHANGE_TOKEN_INVALID` | 400 | Invalid/expired/consumed/wrong-owner change proof |
| `EMAIL_ALREADY_EXISTS` | 409 | Existing signup/email-change conflict |
| `NOT_FOUND` | 404 | Route/resource absent; foreign and absent sessions indistinguishable |
| `RATE_LIMITED` | 429 | A limit that the API already exposes was exceeded |
| `PAYLOAD_TOO_LARGE` | 413 | Request body limit exceeded |
| `UNSUPPORTED_MEDIA_TYPE` | 415 | Missing/unsupported Content-Type |
| `EMAIL_DELIVERY_FAILED` | 502 | Email provider rejected sending |
| `INTERNAL_ERROR` | 500 normally | Unexpected, database, configuration or internal error |
| `HTTP_ERROR` | Original status | Safe fallback for otherwise unmapped Abort status |
| `FORBIDDEN` | 403 | Safe fallback/reserved permission denial |
| `EMAIL_VERIFICATION_REQUIRED` | 403 | Reserved; no current route enforces this policy |

Untyped Abort 5xx statuses are preserved with `INTERNAL_ERROR` and a generic message, even if the
original status is 502/503/etc. Arbitrary non-Abort errors become 500. `HTTP_ERROR` preserves unusual
explicit statuses without publishing their reasons. Clients must support unknown/new codes by
falling back to HTTP status and a generic message. Raw values are explicit, stable enum strings;
Swift names, localized strings and database errors are never used to generate them.

Link proof `INVALID` includes expiration, reuse and invalidation. Cleanup can remove the original
row, so the server intentionally does not promise separate expired-versus-used codes.

## Existing behavior retained

- Validation remains 400, not 422. Current-password failure remains 401, not 400/403.
- Refresh rotation, logout scope and session ownership checks are unchanged.
- Login 429 retains `Retry-After`. Email-change 429 does not expose additional limiter details.
- Forgot-password rate limits/unknown accounts retain the generic 200 response.
- Resend verification retains generic 200 for unknown/already-verified/limited accounts and delivery
  failures. Signup remains successful if the post-commit verification send fails.
- Existing provider HTTP rejections remain 502; unclassified transport failures remain 500.
- Wrong HTTP methods retain the router's existing 404 behavior.
- User-disappearance races retain the existing statuses. In particular, verification translates
  the shared user-lock 401 to an invalid-proof 400 through an `AbortError` catch.
- The broad existing signup/email-change constraint-to-conflict mapping is unchanged.
- Success bodies, JWT payloads, audit retention and maintenance commands are unchanged.

Existing public business messages are retained through closed variants, including the legacy
`Unauthorized` refresh message. Internal/decoder reasons are replaced with safe messages. The
provider failure message now describes email delivery generally rather than password reset only.

## Middleware and security

`APIError` conforms to `AbortError`, allowing the inner route audit middleware to observe 401/429
before the outer `APIErrorMiddleware` serializes the response. Transactions unwind before error
rendering; rollback does not become a successful audit event. Audit write failures remain best-effort.

`APIErrorMiddleware.install` configures the global stack in place of Vapor's default error and raw
route logging middleware. Install other global middleware explicitly if adding it later. The error
middleware logs only the selected status/code using the request logger's correlation context. It
never logs error descriptions, raw URLs, Authorization, bodies, provider responses or SQL bindings.
It applies the same response redaction in development and production. Existing database/client
logging outside this middleware has its own policy and is not automatically sanitized by this layer.

Only typed errors supply public messages. Untyped Abort, DebuggableError, DecodingError and unknown
errors cannot contribute reason, localizedDescription, coding paths, underlying errors or headers.
A positive integer Retry-After is the sole allowed untyped error header. A fixed JSON fallback
handles encoding failure without interpolating diagnostic information. No debug API is installed.

The guarantee covers application-responder errors. Railway edge, TLS/parser failures and connection
termination can happen before middleware; HEAD responses intentionally have no body. There is no new
migration, configuration variable or endpoint for this feature.

## AuthenticationKit / NetworkKit compatibility

Current NetworkKit discards non-2xx bodies and throws `serverError(statusCode)`. Keeping statuses and
legacy JSON keys preserves its current handling, but it cannot yet use the new codes. Neither client
repository is changed by this server work.

A follow-up client change needs to preserve/decode error data and relevant headers, map public codes,
retain unknown-code/legacy-response fallback, and avoid treating `CURRENT_PASSWORD_INVALID` as an
access-expiration signal. Message text is display guidance, not branching logic. Reserved verification
codes do not introduce an email-verification requirement.

## Verification

HTTP middleware tests run in production mode with explicit sensitive sentinel values in untyped
Abort, DebuggableError, DecodingError and unexpected errors. Tests cover code/status consistency,
compatibility decoding, safe headers, malformed input, missing routes and media types. PostgreSQL
integration covers real validation/conflict/auth/rate-limit flows and audit statuses, and holds an
uncommitted user deletion until verification is observed waiting on the user lock, then verifies the
existing 400 invalid-proof result. The complete auth/session/audit/maintenance regression suite runs
through the new global middleware.
