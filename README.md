# WakTrainerServer

**한국어** | [English](README.en.md)

Vapor / Swift 6.3 / PostgreSQL 기반 인증 서버.

## 빌드 환경

Swift 6.3과 macOS 13 이상을 기준으로 개발합니다. 현재 JWT 패키지는 `vapor/jwt 5.1.2`, `jwt-kit 5.6.0`을 사용합니다. JWTKit 5.7.0의 경고 설정이 Xcode의 외부 패키지 경고 숨김 옵션과 충돌하므로 5.6.0으로 고정했습니다.

## 로컬 실행

환경변수 `JWT_SECRET`, `DATABASE_PASSWORD`가 필요합니다. 비밀값은 Git에 저장하지 마세요.
`JWT_SECRET`은 `openssl rand -base64 48`로 생성할 수 있습니다.
`DATABASE_PASSWORD`에는 기존 PostgreSQL에 설정된 비밀번호를 지정합니다.
기존 Docker volume을 사용하는 경우 환경변수 변경만으로 DB 비밀번호가 변경되지는 않습니다.

선택 환경변수:

| 변수 | 기본값 |
| --- | --- |
| DATABASE_HOST | 127.0.0.1 (Docker app에서는 db) |
| DATABASE_PORT | 5432 |
| DATABASE_USERNAME | vapor |
| DATABASE_NAME | waktrainer |

위 환경변수를 설정한 터미널에서 실행합니다.

```sh
docker compose up -d db
swift run WakTrainerServer migrate --yes
swift run WakTrainerServer serve --hostname 127.0.0.1 --port 8080
```

이번 변경에는 `CreateRefreshTokenMigration`이 추가되었습니다. 기존 개발 DB에 마이그레이션을 적용한 뒤 서버를 시작해야 합니다. 테스트는 별도 DB에서 수행하며 개발 DB에 마이그레이션을 자동 적용하지 않습니다.

## 인증 API

JSON 요청에는 `Content-Type: application/json`을 사용합니다.
인증이 필요한 요청에는 `Authorization: Bearer <accessToken>`을 지정합니다.

| 메서드 / 경로 | 요청 | 동작 |
| --- | --- | --- |
| POST /auth/signup | email, password | 사용자 생성 및 토큰 발급 |
| POST /auth/login | email, password | 비밀번호 검증 및 토큰 발급 |
| POST /auth/refresh | refreshToken | 기존 세션을 폐기하고 새 토큰 쌍 발급 |
| GET /auth/me | Bearer | 사용자 id, email 반환 |
| POST /auth/logout | Bearer | 현재 세션 폐기 |
| POST /auth/change-password | Bearer + currentPassword, newPassword | 비밀번호 변경 및 모든 세션 폐기 |
| DELETE /auth/withdraw | Bearer | 사용자 및 모든 세션 삭제 |
| POST /auth/forgot-password | email | 메일 서비스 미설정으로 503 반환 |

Access token은 15분 만료의 JWT이며 `sub`, `exp`, `sid`를 포함합니다.
Refresh token은 시스템 난수로 만든 32바이트 opaque token(64자리 hex)이며 DB에는 SHA-256 해시만 저장합니다. 새 refresh token의 유효기간은 발급부터 30일입니다.

Refresh 성공 시 클라이언트는 access token과 refresh token을 모두 교체해야 합니다. 동일 토큰으로 병렬 refresh 요청을 보내지 마세요. 이전 refresh token과 연결된 access token은 즉시 무효화됩니다.
로그아웃은 현재 세션만 폐기하며 다른 기기의 로그인은 유지합니다.
비밀번호 변경 후에는 모든 기기에서 다시 로그인해야 합니다.
기존 `sid` 없는 JWT와 mock refresh token은 더 이상 인증에 사용할 수 없으므로 다시 로그인해야 합니다.

비밀번호 재설정은 미완료입니다. 메일 제공자와 발신 주소를 정한 뒤 발송, 일회용 재설정 토큰 저장·검증 및 reset-password API를 연결해야 합니다. 현재는 이메일 발송 성공을 가장하지 않고 503을 반환합니다.

## 검증

```sh
swift build
swift test
```

기본 테스트는 DB를 사용하지 않습니다. PostgreSQL 통합 테스트는 `TEST_DATABASE_NAME` 설정 시에만 실행합니다. 데이터베이스 이름은 `waktrainer_test_`로 시작해야 하며, 반드시 비어 있는 일회용 DB를 사용하세요. 테스트는 테이블을 생성하고 종료 시 마이그레이션을 되돌립니다.

선택 설정: `TEST_DATABASE_HOST` (127.0.0.1), `TEST_DATABASE_PORT` (55439), `TEST_DATABASE_USERNAME` (postgres), `TEST_DATABASE_PASSWORD`.

```sh
TEST_DATABASE_NAME=waktrainer_test_auth swift test
```

통합 테스트는 회원가입·중복·로그인 실패, JWT 인증, 동시 refresh 단일 성공, 로그아웃 후 토큰 거부, 비밀번호 변경 후 모든 세션 폐기, 탈퇴 및 세션 삭제를 검증합니다.
