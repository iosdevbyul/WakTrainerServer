# WakTrainerServer

[English](README.md) | **한국어**

WakTrainerServer는 Vapor, Swift 6.3, PostgreSQL 기반의 인증 백엔드 서버입니다.

현재 다음 기능을 지원합니다.

- 회원가입
- 로그인 및 로그아웃
- JWT Access Token
- Refresh Token Rotation
- 현재 사용자 조회
- 활성 세션 조회 및 개별/다른 기기/전체 로그아웃
- 비밀번호 변경
- 이메일 기반 비밀번호 재설정
- 이메일 소유권 인증
- 새 주소 인증 후 이메일 변경
- 회원탈퇴
- 로그인 요청 제한
- 사용자 트리거 이메일 발송 공통 제한
- PostgreSQL 기반 보안 감사 로그

## 요구사항

- Swift 6.3
- 로컬 SwiftPM 개발 기준 macOS 13 이상 또는 제공된 Linux Docker 이미지
- PostgreSQL
- 실제 이메일 발송을 위한 Resend 인증 정보

로컬 Docker Compose 환경에서는 PostgreSQL 16을 사용합니다.

Dockerfile은 `swift:6.3-noble` 이미지를 사용합니다.

JWTKit은 5.7.0의 warnings-as-errors 설정이 Xcode의 외부 패키지 경고 숨김 옵션과 충돌하기 때문에 현재 5.6.0으로 고정되어 있습니다.

현재 의존성 버전은 [Package.swift](Package.swift)와 [Package.resolved](Package.resolved)를 참고하세요.

## 로컬 설정

필요한 값은 프로세스 환경변수 또는 로컬 `.env` 파일에 설정합니다.

비밀값은 절대 커밋하지 마세요.

JWT Secret은 다음과 같이 생성할 수 있습니다.

```sh
openssl rand -base64 48
```

### 환경변수

| 변수 | 필수 여부 / 기본값 |
| --- | --- |
| `AUDIT_HASH_KEY` | 감사 식별값용 별도 HMAC-SHA256 키. 없으면 hash 필드만 생략 |
| `JWT_SECRET` | 필수 |
| `DATABASE_PASSWORD` | 필수 |
| `DATABASE_HOST` | 기본값 `127.0.0.1` |
| `DATABASE_PORT` | 기본값 `5432` |
| `DATABASE_USERNAME` | 기본값 `vapor` |
| `DATABASE_NAME` | 기본값 `waktrainer` |
| `RESEND_API_KEY` | 실제 이메일 발송 시 필수 |
| `PASSWORD_RESET_URL_BASE` | 비밀번호 재설정 링크의 Base URL |
| `EMAIL_CHANGE_URL_BASE` | 이메일 변경 확인 화면의 HTTPS Base URL |
| `EMAIL_VERIFICATION_URL_BASE` | 이메일 인증 링크의 HTTPS 프론트엔드 URL |
| `EMAIL_TRUST_RAILWAY_PROXY` | `true`일 때 신뢰된 Railway `X-Real-IP` 처리 활성화 |

프론트엔드 URL 예시:

```text
https://your-frontend.example/reset-password
https://your-frontend.example/verify-email
https://your-frontend.example/change-email
```

현재 비밀번호 재설정 URL은 서버가 토큰을 Base URL 뒤에 추가하므로, 기존 query string이나 fragment가 없는 URL을 사용하는 것이 좋습니다.

이메일 인증 및 이메일 변경 URL은 호스트가 있는 HTTPS URL이어야 하며 URL에 사용자명이나 비밀번호를 포함할 수 없습니다.
기존 query parameter는 유지하고 `token` parameter는 새 값으로 교체합니다.
해당 URL의 프론트엔드 또는 앱에서 확인 흐름을 구현해야 합니다. 서버는 POST API와 이메일 템플릿을 제공합니다.

## 로컬 실행

PostgreSQL 실행:

```sh
docker compose up -d db
```

Migration 적용:

```sh
swift run WakTrainerServer migrate --yes
```

서버 실행:

```sh
swift run WakTrainerServer serve --hostname 127.0.0.1 --port 8080
```

`.env`의 `DATABASE_PASSWORD`를 변경해도 기존 PostgreSQL Docker volume에 저장된 비밀번호가 자동으로 변경되지는 않습니다.

Dockerfile과 Docker Compose 시작 설정은 database migration을 자동으로 실행하지 않습니다.

## 이메일 발송

이메일 발송은 `EmailSending` abstraction과 Resend provider를 통해 처리합니다.

사용자가 직접 트리거하는 이메일 발송은 실제 전송 전에 공통 이메일 rate limiter를 통과합니다.

현재 지원하는 이메일 흐름:

- 비밀번호 재설정
- 이메일 인증
- 이메일 인증 재전송
- 이메일 변경 인증

개발 환경에서는 현재 Resend onboarding sender를 사용합니다. 운영 발신자 정보를 사용하려면 검증된 sender와 domain을 설정해야 합니다.

## Database Migration

업데이트된 서버를 실행하기 전에 모든 미적용 migration을 실행해야 합니다.

현재 migration 등록 순서:

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

`AddEmailVerificationMigration`은 사용자 이메일 인증 상태와 이메일 인증 토큰 테이블을 추가합니다.

기존 사용자는 초기 상태가 미인증으로 설정되지만 기존과 동일하게 로그인할 수 있습니다.

`AddEmailChangeMigration`은 변경 대기 토큰을 위한 별도 테이블을 추가합니다.
`AddSessionMetadataMigration`은 기존 세션 값을 변경하지 않고 nullable metadata 컬럼을 추가하며,
컬럼 변경 시 잠금 대기 시간을 5초로 제한합니다. `IndexSessionUserExpiryMigration`은 사용자별 만료 조회용
인덱스를 동시에 생성하며 트랜잭션 밖에서 실행해야 합니다. 현재 Fluent migrator는 이 방식을 지원합니다.

기존 pre-deploy 명령으로 migration을 적용하세요. 구버전 코드는 refresh 시 관리용 ID를 계승하지 않으므로,
세션 관리 기능을 사용하기 전에 모든 서버 인스턴스를 업데이트해야 합니다.
재시도와 rollback에 관한 내용은 [세션 관리 배포 문서](docs/session-management.md#railway-migration)를 참고하세요.

테스트는 별도의 PostgreSQL 데이터베이스를 사용하며 개발 DB에는 migration을 적용하지 않습니다.

## 인증 API

JSON 요청에는 다음 헤더를 사용합니다.

```http
Content-Type: application/json
```

인증이 필요한 endpoint에는 다음 헤더를 사용합니다.

```http
Authorization: Bearer <accessToken>
```

### Endpoint

| Method | Path | 설명 |
| --- | --- | --- |
| POST | `/auth/signup` | 사용자 생성 및 세션 발급 |
| POST | `/auth/login` | 사용자 인증 및 세션 발급 |
| POST | `/auth/refresh` | Refresh Token 및 세션 교체 |
| GET | `/auth/me` | 현재 인증된 사용자 조회 |
| POST | `/auth/logout` | 현재 세션 폐기 |
| GET | `/auth/sessions` | 본인의 활성 세션 목록 |
| DELETE | `/auth/sessions/:sessionID` | 관리용 ID로 본인의 특정 세션 폐기 |
| POST | `/auth/logout-other-sessions` | 현재 세션 외 모두 폐기 |
| POST | `/auth/logout-all` | 현재 세션 포함 모두 폐기 |
| POST | `/auth/change-password` | 비밀번호 변경 및 세션 폐기 |
| DELETE | `/auth/withdraw` | 회원탈퇴 |
| POST | `/auth/forgot-password` | 비밀번호 재설정 메일 요청 |
| POST | `/auth/reset-password` | 재설정 토큰을 이용한 비밀번호 변경 |
| POST | `/auth/verify-email` | 이메일 인증 토큰을 이용한 소유권 인증 |
| POST | `/auth/resend-verification-email` | 이메일 인증 메일 재전송 |
| POST | `/auth/request-email-change` | 새 이메일로 변경 인증 요청 (Bearer + 현재 비밀번호) |
| POST | `/auth/confirm-email-change` | 이메일 변경 완료 (동일 사용자 Bearer + token) |

이메일 변경은 현재 비밀번호와 Bearer 인증으로 요청하고, 동일 사용자 Bearer와 메일 토큰으로 완료합니다.
완료 요청 세션만 유지하며 새 이메일은 인증 완료 전까지 계정에 적용하지 않습니다.
`AddEmailChangeMigration`은 기존 데이터 변경 없이 별도 토큰 테이블을 추가합니다.
요청/응답, 배포와 토큰 정책은 [이메일 변경 문서](docs/email-change.md)를 참고하세요.

세션 관리 API는 Bearer 인증을 요구합니다. 선택적인 `X-Device-Name`은 signup/login의 표시용 metadata이며 인증 수단이 아닙니다.
관리용 ID는 refresh 후에도 유지되지만 JWT sid는 기존처럼 교체됩니다.
`createdAt`은 현재 행 생성 시각, `startedAt`은 로그인 시작 시각, `lastRefreshedAt`은 마지막 refresh 성공 시각입니다.
기존 클라이언트의 세션 응답은 변경하지 않습니다. API·정리·배포 세부 사항은 [세션 관리](docs/session-management.md)를 참고하세요.

### Session 응답

Signup, Login, Refresh는 동일한 session 구조를 반환합니다.

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

기타 변경성 endpoint는 일반적으로 다음 형태의 성공 응답을 반환합니다.

```json
{
  "message": "..."
}
```

오류는 Vapor의 표준 error response 형식을 사용합니다.

일부 API 메시지는 현재 한국어입니다. README 언어와 API 응답 언어는 별개입니다.

## 입력 규칙

비밀번호:

- 7자 이상 20자 이하
- UTF-8 기준 최대 72바이트

이메일 검증:

- UTF-8 기준 최대 254바이트
- `@` 포함
- `.` 포함

이미 존재하는 이메일로 회원가입하면 HTTP `409`를 반환합니다.

회원가입·로그인·이메일 변경은 전달받은 이메일 문자열을 그대로 비교하거나 저장하며, 앞뒤 공백 제거 또는 소문자 변환을 하지 않습니다.
Rate limit은 요청 제한 카운터를 묶기 위해 이메일의 앞뒤 공백을 제거하고 소문자로 변환합니다.

## 세션

Access Token:

- JWT 기반
- 약 15분 만료
- `sub`, `exp`, `sid` 포함
- DB의 유효한 세션과 함께 검증

Refresh Token:

- 시스템 난수 32바이트 사용
- 64자리 hexadecimal 문자열로 표현
- DB에는 SHA-256 hash만 저장
- 약 30일 만료
- 성공적인 refresh 후 교체

Refresh 성공 후 클라이언트는 access token과 refresh token을 모두 새 값으로 교체해야 합니다.

동일한 refresh token을 동시에 사용하는 요청은 하나의 요청만 성공할 수 있습니다.

Logout은 현재 세션만 폐기합니다.

비밀번호 변경 및 비밀번호 재설정은 모든 세션을 폐기하고 대기 중인 이메일 변경을 취소합니다.
이메일 변경 완료 시에는 완료 요청 세션만 유지하고 새 주소를 인증된 상태로 설정합니다.
`logout-other-sessions`는 호출한 현재 세션만 유지하고, `logout-all`은 현재 세션도 폐기합니다.

유효한 session identifier가 없는 JWT는 허용하지 않습니다.

### 세션 관리

`GET /auth/sessions`는 인증된 사용자의 만료되지 않은 세션만 반환합니다.

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

`createdAt`은 현재 refresh 행의 생성 시각이고, `startedAt`은 rotation 후에도 유지됩니다.
`lastRefreshedAt`은 각 API 요청 시각이 아니라 마지막 refresh 성공 시각만 기록합니다.
날짜는 초 단위 ISO-8601 형식입니다. 값이 없는 optional 필드는 생략합니다.
기존 세션은 남아 있는 가장 오래된 행의 생성 시각을 초기 `startedAt`으로 사용하므로 실제 최초 로그인 시각과 다를 수 있습니다.

`DELETE /auth/sessions/:sessionID`에는 JWT `sid`가 아닌 목록에서 반환한 관리용 `id`를 사용합니다.
현재 세션도 삭제할 수 있습니다. 다른 사용자 소유 ID와 존재하지 않는 ID는 동일한 `404`를 반환하고,
UUID 형식이 잘못되면 `400`을 반환합니다. 삭제 성공 시 `message` 응답을 반환합니다.
삭제된 세션의 access token과 refresh token은 이후 검증에 실패합니다.

signup/login의 `X-Device-Name`은 선택 사항이며, 단일 헤더·UTF-8 기준 최대 128바이트·제어문자 없음 조건을 적용합니다.
앞뒤 공백은 제거하고, 잘못되거나 누락된 이름은 무시합니다. Refresh는 저장된 이름을 유지합니다.
세션 metadata에 clientId, IP, User-Agent는 저장하지 않으며 목록에 토큰 원문이나 해시를 반환하지 않습니다.

Refresh와 세션 폐기는 동일한 사용자별 DB 잠금을 사용합니다. 관리용 ID는 교체된 후속 세션에도 유지되므로,
대상 세션이 먼저 refresh되었다는 이유로 폐기 대상에서 빠지지 않습니다.
호출한 세션 자체가 먼저 refresh되면 기존 Bearer token이 무효화되어 관리 요청에 `401`이 반환될 수 있습니다.
이 경우 새로 발급된 Bearer token으로 다시 요청하세요.

세션 발급과 목록 조회 시 해당 사용자의 만료 행을 최대 100개씩 정리합니다.
정리할 행이 남아 있더라도 활성 목록에서는 모든 만료 행을 제외합니다.
활동이 없는 계정의 만료 행은 남을 수 있으며, 별도 백그라운드 정리 scheduler는 없습니다.

### 이메일 인증 상태

미인증 사용자도 다음 기능을 그대로 사용할 수 있습니다.

- 회원가입
- 로그인
- Refresh
- 일반적인 인증 세션 흐름

이메일 인증은 세션을 새로 만들거나 폐기하지 않습니다.

클라이언트는 다음 endpoint를 호출해 최신 `isEmailVerified` 상태를 갱신할 수 있습니다.

```http
GET /auth/me
```

향후 이메일 소유권 인증이 필요한 기능은 서버에서 사용자의 인증 상태를 확인해야 합니다.

## 비밀번호 재설정

비밀번호 재설정 토큰:

- 시스템 난수 32바이트 사용
- DB에는 SHA-256 hash만 저장
- 약 30분 만료
- 일회성
- 새 토큰 발급 시 기존 토큰 교체

비밀번호 재설정 성공 시:

- 비밀번호 변경
- 남아 있는 재설정 토큰 삭제
- 대기 중인 이메일 변경 취소
- 모든 세션 폐기

존재하지 않는 계정과 rate limit에 의해 제한된 forgot-password 요청은 account enumeration 위험을 줄이기 위해 동일한 성공 응답을 반환합니다.

일반적인 성공 응답이 실제 이메일 수신함 도착을 보장하지는 않습니다.

## 이메일 인증

이메일 인증 토큰:

- 시스템 난수 32바이트 사용
- DB에는 SHA-256 hash만 저장
- 약 24시간 만료
- 일회성
- 새 인증 토큰 발급 시 기존 토큰 교체

이메일 인증은 다음 endpoint를 사용합니다.

```http
POST /auth/verify-email
```

이 endpoint는 로그인하지 않은 상태에서도 사용할 수 있습니다.

인증 성공 시:

```text
isEmailVerified = true
```

잘못된 토큰, 만료된 토큰, 교체된 토큰, 이미 사용된 토큰 등 유효하지 않은 인증 토큰은 거부됩니다.

인증 메일 재전송은 다음 endpoint를 사용합니다.

```http
POST /auth/resend-verification-email
```

외부 응답은 의도적으로 다음 상태를 구분하지 않습니다.

- 계정이 존재하는지 여부
- 이미 인증된 계정인지 여부
- rate limit에 걸렸는지 여부
- 이메일 발송이 억제되었는지 여부

이는 account enumeration 위험을 줄이기 위한 정책입니다.

`EMAIL_VERIFICATION_URL_BASE`는 다음과 같은 HTTPS 프론트엔드 URL로 설정합니다.

```text
https://your-frontend.example/verify-email
```

서버가 token query parameter를 추가합니다. 프론트엔드는 앱으로 연결하거나 Universal Links를 사용한 뒤
POST로 토큰을 제출할 수 있습니다. `waktrainer://` 같은 커스텀 URL scheme은 Base URL 설정값으로 허용되지 않습니다.
GET 링크를 여는 것만으로 이메일 인증이 완료되지는 않습니다.

인증 메일 발송이 실패해도 회원가입은 성공 상태를 유지합니다. 재전송 역시 발송 실패 시 일반적인 성공 메시지를 반환합니다.
사용자는 인증 메일을 다시 요청할 수 있습니다.

## 이메일 변경

Bearer 인증으로 이메일 변경을 요청합니다.

```http
POST /auth/request-email-change
```

```json
{"currentPassword":"<current password>","newEmail":"new@example.com"}
```

변경 대기 중에는 계정 이메일과 인증 상태를 유지합니다. 현재 비밀번호가 일치해야 합니다.
현재와 같은 이메일이면 `400`, 이미 사용 중인 주소이면 `409`, 요청 제한에 걸리면 `429`를 반환합니다.
공통 이메일 gateway는 토큰을 준비하기 전에 `emailChangeVerification` action의 제한 횟수를 소비합니다.

동일 사용자의 유효한 Bearer 세션으로 변경을 완료합니다. 변경 요청을 시작한 세션과 같을 필요는 없습니다.

```http
POST /auth/confirm-email-change
```

```json
{"token":"<token from the email link>"}
```

변경 토큰은 난수 32바이트로 생성하고 SHA-256 해시로 저장하며, 유효 시간은 30분이고 일회성입니다.
새 토큰을 발급하면 이전 토큰은 무효화됩니다. 발송 실패 시 해당 요청이 만든 토큰만 삭제합니다.
이전 토큰은 복구하지 않으며 사용자가 메일을 다시 요청할 수 있습니다.

완료 시 이메일 중복을 다시 검사하고 주소를 변경한 뒤 `isEmailVerified = true`로 설정하며,
완료 요청 세션만 유지합니다. 변경 토큰과 남아 있는 이메일 인증·비밀번호 재설정 토큰도 삭제합니다.
`/auth/me`와 이후 refresh 응답에 새 이메일이 반영됩니다.
잘못된 토큰, 만료·재사용된 토큰, 다른 사용자 토큰은 `400`을 반환하고, 완료 전에 주소가 이미 사용 중이 되면 `409`를 반환합니다.
요청과 완료 성공 응답은 기존 `message` 형식을 사용합니다.

실패 복구와 동시성에 관한 내용은 [이메일 변경 문서](docs/email-change.md)를 참고하세요.

## Rate Limiting

### 로그인

로그인 시 PostgreSQL 기반 counter를 사용합니다.

현재 정책:

- IP당 분당 30회
- 이메일당 15분 동안 10회

성공 및 실패 요청 모두 제한 횟수에 포함됩니다.

한도 초과 시 HTTP `429`를 반환합니다.

### 사용자 트리거 이메일 발송

이메일 요청은 공통 PostgreSQL 기반 limiter를 사용합니다.

다음 여러 abuse signal을 함께 사용합니다.

- 수신 이메일 주소
- Client ID
- IP 주소
- 이메일 action
- 전체 발송량

Limiter에 저장하는 수신자·클라이언트·IP·action 식별자는 SHA-256 해시를 사용하며, 전체 제한 버킷은 고정 키를 사용합니다.

`X-Client-ID`는 선택 사항이며 인증 수단이 아니라 abuse 방지용 signal로만 사용됩니다.

현재 세부 제한 정책은 다음 문서를 참고하세요.

[docs/email-rate-limits.md](docs/email-rate-limits.md)

현재 사용 중인 action:

- `passwordReset`
- `signUpVerification`
- `emailChangeVerification`

### Railway Proxy 처리

기본적으로 이메일 rate limiting은 직접 연결된 IP 주소를 사용합니다.

다음 설정이 활성화된 경우:

```text
EMAIL_TRUST_RAILWAY_PROXY=true
```

검증된 Railway `X-Real-IP` 값을 이메일 rate limiting에 사용할 수 있습니다.

배포 구조상 요청이 신뢰된 Railway edge를 통해 들어온다는 것이 보장될 때만 활성화해야 합니다.

임의의 `X-Forwarded-For` 값은 신뢰하지 않습니다.

## 보안 감사 로그

주요 인증·세션·비밀번호·이메일 변경·회원탈퇴 및 요청 제한 이벤트를 별도 `audit_logs` 테이블에 기록합니다.
이벤트별 기록 의미는 [감사 로그 문서](docs/audit-logging.md)를 참고하세요. 조회 API는 제공하지 않습니다.

비즈니스 transaction 성공 후 best-effort로 기록하며, audit 저장 실패로 인증 응답을 변경하지 않습니다.
완전한 기록 보장은 아니며 과부하·timeout·프로세스 종료 시 누락될 수 있습니다.
별도 audit 연결 풀과 짧은 timeout으로 인증 풀에 미치는 영향을 제한합니다.

이메일/IP/clientId 원문은 저장하지 않고, AUDIT_HASH_KEY로 HMAC-SHA256 처리합니다.
키가 없으면 hash 필드만 생략합니다. 해시도 가명 식별 정보로 취급해야 합니다.
Credential·토큰·토큰 해시·secret·기기 이름·User-Agent·요청 body·오류 원문은 기록하지 않습니다.
metadata는 허용된 enum과 숫자 필드만 담습니다.

로그인/refresh 실패, 요청 제한, 익명 메일 요청은 eventType과 식별 해시, action(이메일 제한),
분 단위 bucket으로 중복 억제합니다. 서로 다른 source를 전역 한 건으로 합치지 않으며 정확한 요청 횟수 집계는 아닙니다.
회원탈퇴 시 기존 이력은 user_id를 null로 바꿔 보존합니다.

보존 기준은 90일이며 **자동 삭제는 5번 DB maintenance 작업에서 구현할 예정**입니다.
그 전에는 자동으로 만료되지 않습니다. 운영 조회·수동 정리 SQL과 migration 설명은 [감사 로그 문서](docs/audit-logging.md)를 참고하세요.

## 테스트

실행:

```sh
swift build
swift test --disable-sandbox
```

PostgreSQL 통합 테스트에는 정확히 다음 이름의 폐기 가능한 테스트 DB가 필요합니다.

```text
waktrainer_test_auth
```

설정:

```text
TEST_DATABASE_NAME=waktrainer_test_auth
```

그리고 다음 연결 정보를 테스트 DB에 맞게 설정합니다.

- `TEST_DATABASE_HOST`
- `TEST_DATABASE_PORT`
- `TEST_DATABASE_USERNAME`
- `TEST_DATABASE_PASSWORD`

로컬 Docker Compose는 개발용 `waktrainer` DB만 생성하므로 통합 테스트용 DB는 별도로 준비해야 합니다.

통합 테스트는 다음을 사용합니다.

- Mock 이메일 발송
- 실제 PostgreSQL
- 실제 migration

테스트 DB 설정이 누락되거나 안전하지 않은 경우 테스트는 skip하지 않고 실패합니다.

동일한 폐기용 테스트 DB를 대상으로 여러 통합 테스트나 E2E 테스트를 동시에 실행하지 마세요.

현재 테스트 범위:

- 회원가입
- 로그인
- Refresh Rotation
- Logout
- 회원탈퇴
- 비밀번호 변경
- 비밀번호 재설정
- 로그인 rate limiting
- 공통 이메일 rate limiting
- 이메일 인증 및 새 주소 인증 후 이메일 변경
- 세션 소유권·현재 세션 식별·metadata·폐기
- Refresh와 폐기의 경합 및 사용자별 만료 세션 정리
- 토큰 만료
- 일회성 토큰 동작
- 동시 토큰 소비
- account enumeration 방지 응답
- Migration upgrade/revert 및 기존 사용자·세션 보존

Mock 이메일 테스트는 실제 수신함 도착 여부를 검증하지 않습니다.

## 운영 배포

WakTrainerServer는 현재 Railway에 배포되어 있습니다.

현재 운영 구조:

- 애플리케이션 호스팅: Railway
- 데이터베이스: Railway PostgreSQL
- 외부 API 트래픽: Railway HTTPS domain
- 비밀값 관리: Railway environment variables
- 이메일 provider: Resend
- 데이터베이스 연결: Railway private network

운영 migration은 Railway pre-deploy command로 실행합니다.

```sh
./WakTrainerServer migrate --env production --yes
```

애플리케이션은 현재 Railway private network를 통해 PostgreSQL에 연결하며, 애플리케이션 레벨에서 PostgreSQL TLS는 비활성화되어 있습니다.

운영 환경에는 다음과 같은 환경변수가 필요합니다.

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

`AUDIT_HASH_KEY`는 선택 사항입니다. 운영에서는 별도 키 설정을 권장하며, 없으면 감사 이벤트는 기록하되 식별 hash 필드만 생략합니다.

`EMAIL_TRUST_RAILWAY_PROXY`는 trusted proxy 구성을 확인한 뒤에만 활성화해야 합니다.

서비스가 성장하면 운영 모니터링, 실제 발신자/domain 설정, DB backup 전략, 전체 API 단위 abuse protection 등을 추가로 검토해야 합니다.

## 문서

추가 문서:

- [보안 감사 로그](docs/audit-logging.md)
- [세션 관리](docs/session-management.md)
- [이메일 변경](docs/email-change.md)
- [이메일 인증](docs/email-verification.md)
- [공통 이메일 발송 제한](docs/email-rate-limits.md)
- [AuthenticationKit Demo E2E 가이드](docs/authentication-e2e.md)
