# AuthenticationKit Demo server integration

The Demo uses the local AuthenticationKit package and TrisNetworkKit 0.1.0. All E2E requests use the real `URLSessionNetworkClient`, `AuthorizationRequestInterceptor`, WakTrainerServer routes, Fluent, and PostgreSQL. No mock repository or email replacement is installed in the E2E server.

## Safe local execution

Prerequisites: Xcode with an available iOS 17+ simulator, running Docker PostgreSQL, and a dedicated database named exactly `waktrainer_test_auth`. Keep `TEST_DATABASE_NAME`, `TEST_DATABASE_HOST`, `TEST_DATABASE_PORT`, `TEST_DATABASE_USERNAME`, `TEST_DATABASE_PASSWORD`, `JWT_SECRET`, and mail configuration in the ignored server `.env` or process environment. Never commit that file.

`WakTrainerServer --env testing` selects only `TEST_DATABASE_*` and refuses every database name except `waktrainer_test_auth`, before opening a connection. Development configuration remains unchanged.

From WakTrainerServer:

```sh
xcrun simctl list devices available
python3 scripts/run-authentication-e2e.py \
  --authentication-kit ../AuthenticationKit \
  --simulator '<available iOS simulator UDID>'
```

The runner refuses to start if port 8080 is already occupied. It builds the server, applies migrations in testing mode, starts its own server on `127.0.0.1:8080`, builds the Demo, creates a disposable password reset fixture, and runs the Demo's API and UI tests. It stops its server and reverts the test migrations in `finally`. It never stops a pre-existing server. Do not run server integration tests or another E2E runner concurrently against this shared disposable database.

Build logs, test logs, and `E2E.xcresult` are saved in the printed temporary artifact directory. Random reset credentials are injected into a private `.xctestrun` file and removed after execution. Neither the runner nor the tests print token values. E2E fixture requests use synthetic `example.com` accounts; no real mail is sent by the automated suite.

For AuthenticationKit unit tests, run from AuthenticationKit:

```sh
xcodebuild test -scheme AuthenticationKit \
  -destination 'platform=iOS Simulator,id=<available simulator UDID>' \
  -parallel-testing-enabled NO
```

## Coverage

- Sign up: accepts password lengths 7 and 20; rejects 6 and 21; persists a real user; receives user/access/refresh fields; rejects duplicate email.
- Login: valid credentials succeed; wrong passwords and unknown emails both fail with 401.
- Session: real storage is saved/restored; protected requests use `Bearer`; a unit regression test also checks the exact header.
- Current user: `/auth/me` returns the signed-in user; tampered and revoked tokens fail.
- Refresh: explicit `AuthenticationService.refreshSession()` calls `/auth/refresh` and persists both rotated tokens. Used refresh tokens and old access tokens fail. Automatic 401 retries are not introduced.
- Change password: old sessions are revoked on the server and cleared locally; old password fails and new password succeeds.
- Forgot password: unknown email returns success without revealing existence. The real Resend implementation remains installed, but actual inbox delivery requires a user-owned email.
- Reset password: real HTTP requests validate an expired PostgreSQL fixture token, consume a valid token, reject reuse, invalidate old sessions/password, and allow the new password. The fixture seeds hashes directly; this does not prove inbox delivery or a token obtained from mail.
- Logout and withdraw: call real endpoints, clear local session/storage, reject subsequent protected requests or login. Remaining user/token counts are checked in PostgreSQL during verification.
- Demo UI test: types credentials into the real SignUpView/LoginView, waits for their Session callbacks, and exercises current user, refresh, logout, and withdraw.

## Manual mail verification

Start the server in testing mode after migration, then launch the Demo. Use an email address whose inbox you control. Sign up, open Forgot Password, submit that same email, and verify the Resend email arrives. Copy the token from its reset URL into the Demo's Reset Password screen, set a new password, log in with it, and confirm that reusing the token fails. The Demo supports token entry; universal links/custom URL routing are not configured by this change.

`LoginView` keeps `onLoginSuccess(Session)`. Failure presentation remains `errorMessage`. The public repository and token-storage injection initializer remains available so NetworkKit can still be replaced. Existing custom repositories remain source compatible; new operations throw `unsupportedOperation` until implemented.

## Changes by file

AuthenticationKit:

| File | Reason |
| --- | --- |
| `Data/Endpoints/AuthenticationEndpoint.swift` | Map current-user, refresh, and reset routes and HTTP bodies. |
| `Data/DTOs/RefreshTokenRequestDTO.swift`, `ResetPasswordRequestDTO.swift` | Encode the server's exact payloads. |
| `Data/Repositories/NetworkAuthenticationRepository.swift` | Use the existing network client for the three missing APIs. |
| `Domain/Repositories/AuthenticationRepository.swift`, `Domain/Authentication/AuthenticationError.swift` | Expose the APIs while keeping older custom repositories source compatible. |
| `Domain/UseCases/RefreshSessionUseCase.swift`, `ResetPasswordUseCase.swift` | Persist rotated sessions and expose reset through the existing use-case layer. |
| `Domain/Service/AuthenticationService.swift` | Wire the existing Bearer interceptor to the same SessionManager and clear sessions after password changes/reset. |
| `Presentation/ResetPassword/ResetPasswordView.swift`, `ResetPasswordViewModel.swift` | Add an iOS 17+ token-entry screen with existing errorMessage behavior. |
| `Presentation/Components/AuthenticationSecureField.swift` | Give the existing visibility toggle an accessible name for UI tests and assistive technologies. |
| `Tests/AuthenticationKitTests/Services/AuthenticationServiceNetworkTests.swift` | Add exact header, refresh persistence, reset payload, and session cleanup regression tests. |
| `Example/AuthenticationKitDemo/AuthenticationKitDemo/ContentView.swift` | Show session state without printing tokens, own view models, and expose actual protected operations/reset UI. |
| `Example/AuthenticationKitDemo/AuthenticationKitDemo.xcodeproj/project.pbxproj` | Set the Demo's deployment target to iOS 17. |
| `Example/AuthenticationKitDemo/AuthenticationKitDemoTests/AuthenticationKitDemoTests.swift` | Replace placeholder tests with real HTTP/PostgreSQL lifecycle and reset fixture tests. |
| `Example/AuthenticationKitDemo/AuthenticationKitDemoUITests/AuthenticationKitDemoUITests.swift` | Exercise the actual Demo screens and wait for success callbacks. |

WakTrainerServer:

| File | Reason |
| --- | --- |
| `Sources/WakTrainerServer/configure.swift` | Make the actual server's testing environment use only the explicitly named test DB. |
| `scripts/run-authentication-e2e.py` | Reproducibly build, run, seed, test, and clean up an isolated E2E server. |
| `docs/authentication-e2e.md` | Document execution, actual coverage, mail limitations, and changes. |

The Demo's `AuthenticationKitDemoApp.swift` and `Package.resolved` were already modified before this work; their existing local base URL/dependency changes were preserved. TrisNetworkKit was not modified.
