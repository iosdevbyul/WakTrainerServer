# WakTrainerServer

[English](README.md) | **한국어**

WakTrainerServer는 Vapor, Swift 6.3, PostgreSQL 기반의 인증 백엔드 서버입니다.

현재 다음 기능을 지원합니다.

- 회원가입
- 로그인 및 로그아웃
- JWT Access Token
- Refresh Token Rotation
- 현재 사용자 조회
- 비밀번호 변경
- 이메일 기반 비밀번호 재설정
- 이메일 소유권 인증
- 새 주소 인증 후 이메일 변경
- 회원탈퇴
- 로그인 요청 제한
- 사용자 트리거 이메일 발송 공통 제한

## 요구사항

- Swift 6.3
- 로컬 SwiftPM 개발 기준 macOS 13 이상
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
| `JWT_SECRET` | 필수 |
| `DATABASE_PASSWORD` | 필수 |
| `DATABASE_HOST` | 기본값 `127.0.0.1` |
| `DATABASE_PORT` | 기본값 `5432` |
| `DATABASE_USERNAME` | 기본값 `vapor` |
| `DATABASE_NAME` | 기본값 `waktrainer` |
| `RESEND_API_KEY` | 실제 이메일 발송 시 필수 |
| `PASSWORD_RESET_URL_BASE` | 비밀번호 재설정 링크의 Base URL |
| `EMAIL_CHANGE_URL_BASE` | 이메일 변경 확인 화면의 HTTPS Base URL |
| `EMAIL_VERIFICATION_URL_BASE` | 이메일 인증 링크의 Base URL |
| `EMAIL_TRUST_RAILWAY_PROXY` | `true`일 때 신뢰된 Railway `X-Real-IP` 처리 활성화 |

프론트엔드 URL 예시:

```text
https://your-frontend.example/reset-password
https://your-frontend.example/verify-email
https://your-frontend.example/change-email
```

현재 비밀번호 재설정 URL은 서버가 토큰을 Base URL 뒤에 추가하므로, 기존 query string이나 fragment가 없는 URL을 사용하는 것이 좋습니다.

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

`AddEmailVerificationMigration`은 사용자 이메일 인증 상태와 이메일 인증 토큰 테이블을 추가합니다.

기존 사용자는 초기 상태가 미인증으로 설정되지만 기존과 동일하게 로그인할 수 있습니다.

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

Rate limit에서 사용하는 이메일 정규화는 계정 저장 정책과 별개입니다.

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

비밀번호 변경 및 비밀번호 재설정은 모든 활성 세션을 폐기합니다.

유효한 session identifier가 없는 JWT는 허용하지 않습니다.

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
- 모든 활성 세션 폐기

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

이메일 인증 링크는 토큰을 추출한 뒤 인증 endpoint로 전달할 수 있는 프론트엔드 또는 앱 진입점으로 연결되어야 합니다.

예:

```text
waktrainer://verify-email?token=...
```

운영 HTTPS 프론트엔드가 앱으로 넘기거나 Universal Links를 사용할 수도 있습니다.

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

Limiter 저장용 식별자는 SHA-256 hash로 저장됩니다.

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

## 테스트

실행:

```sh
swift build
swift test
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
- 이메일 인증
- 토큰 만료
- 일회성 토큰 동작
- 동시 토큰 소비
- account enumeration 방지 응답
- 기존 사용자를 포함한 migration 동작

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
```

`EMAIL_TRUST_RAILWAY_PROXY`는 trusted proxy 구성을 확인한 뒤에만 활성화해야 합니다.

서비스가 성장하면 운영 모니터링, 실제 발신자/domain 설정, DB backup 전략, 전체 API 단위 abuse protection 등을 추가로 검토해야 합니다.

## 문서

추가 문서:

- [이메일 인증](docs/email-verification.md)
- [공통 이메일 발송 제한](docs/email-rate-limits.md)
- [AuthenticationKit Demo E2E 가이드](docs/authentication-e2e.md)
