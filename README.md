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

## 로그인 요청 제한

`POST /auth/login`은 PostgreSQL의 `login_rate_limits` 테이블로 요청 횟수를 공유합니다. `CreateLoginRateLimitMigration`을 적용해야 합니다.

- 직접 연결된 IP당 60초에 30회, 이메일당 15분에 10회를 허용합니다.
- 로그인 성공·실패 모두 집계하며, 성공했다고 카운터를 초기화하지 않습니다. IP 제한은 JSON 해석 전에, 이메일 제한은 입력 검증 후 계정 조회와 bcrypt 검증 전에 적용합니다.
- 초과하면 `429 Too Many Requests`와 초 단위 `Retry-After`를 반환합니다. 고정된 기간이 지나면 다시 허용하며 초과 요청이 기간을 연장하지 않습니다.
- 이메일 제한 키에만 앞뒤 공백 제거와 소문자 변환을 적용합니다. 실제 회원가입 저장 및 로그인 조회 정책은 아직 대소문자를 구분합니다.
- IP·이메일 원문 대신 SHA-256 해시를 저장합니다. 원문을 추측해 해시를 비교할 수 있으므로 익명 데이터로 취급하면 안 됩니다.
- DB의 원자적 upsert와 DB 시각을 사용해 여러 인스턴스와 동시 요청에서 제한을 공유합니다. DB 오류 시 로그인을 통과시키지 않습니다.
- 만료된 항목은 로그인 요청마다 최대 100개씩 정리합니다.

`X-Forwarded-For` 등 전달 헤더는 신뢰하지 않습니다. 프록시 뒤에서는 프록시 IP 단위로 제한되므로, 배포 전에 신뢰할 프록시와 실제 클라이언트 IP 전달 정책을 구현해야 합니다. IP를 알 수 없는 요청은 하나의 공통 제한을 공유합니다.

이 제한값은 초기 정책입니다. 이메일 단위 제한은 타인이 해당 이메일의 로그인을 일시적으로 막을 수 있으므로 실제 사용량과 차단 지표를 관찰하며 조정해야 합니다. 회원가입·토큰 갱신 등 다른 API의 제한과 인프라 수준의 트래픽 방어는 별도 작업입니다. 참고: [OWASP Login Throttling](https://cheatsheetseries.owasp.org/cheatsheets/Authentication_Cheat_Sheet.html#login-throttling).

## 인터넷 공개 전 남은 작업

현재 Docker Compose와 PostgreSQL `tls: .disable` 설정은 로컬 개발 기준입니다. 다음 항목을 완료하기 전에는 운영 환경 준비가 끝난 것으로 간주하지 않습니다.

- HTTPS 종료 지점과 인증서 갱신, 신뢰할 프록시 및 클라이언트 IP 정책 설정
- 운영 PostgreSQL TLS와 서버 인증서/호스트명 검증, DB 네트워크 접근 제한
- Secret Manager 또는 배포 환경을 통한 비밀값 주입과 교체 정책
- 비밀번호·토큰을 기록하지 않는 로그 정책 및 오류율·로그인 실패·429 모니터링/알림
- 이메일 유효성 검사 강화 및 소문자/공백 정책 결정, 기존 계정 충돌 검사 후 마이그레이션
- Swift/Xcode/JWT 업데이트 시 JWTKit 5.6.0 pin 재검토와 Xcode/터미널 빌드·인증 회귀 테스트
- 비밀번호 재설정 메일 서비스 및 일회용 재설정 토큰 구현

## 검증

```sh
swift build
swift test
```

기본 테스트는 DB를 사용하지 않습니다. `swift test`는 PostgreSQL 통합 테스트도 실행합니다. 앱이 `.env`를 읽은 뒤 `TEST_DATABASE_NAME`이 정확히 `waktrainer_test_auth`인지 검증하며, 누락되거나 다른 이름이면 skip 대신 실패합니다. 개발 DB `waktrainer`는 사용하지 않습니다. 반드시 테스트 전용 DB를 사용하세요. 테스트는 테이블을 생성하고 정상 종료 시 마이그레이션을 되돌립니다.

선택 설정: `TEST_DATABASE_HOST` (127.0.0.1), `TEST_DATABASE_PORT` (5432), `TEST_DATABASE_USERNAME` (vapor), `TEST_DATABASE_PASSWORD`.

```sh
# .env에 TEST_DATABASE_NAME 및 TEST_DATABASE_* 접속 정보를 설정한 뒤 실행
swift test
```

통합 테스트는 회원가입·중복·로그인 실패, JWT 인증, 동시 refresh 단일 성공, 로그아웃 후 토큰 거부, 비밀번호 변경 후 모든 세션 폐기, 탈퇴 및 세션 삭제를 검증합니다.

비밀번호 재설정 통합 테스트는 mock 메일 서비스와 실제 PostgreSQL을 사용해 토큰 생성, 재설정 성공, 사용·만료 토큰 거부, 기존 비밀번호 거부, 새 비밀번호 로그인 및 기존 세션 폐기를 검증합니다.
