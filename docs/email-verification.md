# 회원가입 이메일 인증

## 로그인 및 기존 사용자 정책

미인증 사용자도 기존처럼 signup/login/refresh를 사용한다.
회원가입 시 발급하는 access/refresh token, JWT 내용, 세션 검증/폐기 규칙은 유지한다.
User에 `isEmailVerified`를 추가하고 signup/login/refresh의 `user` 및 GET /auth/me 응답에
같은 Boolean 필드를 추가한다. 기존 필드는 유지된다.

새 계정과 기존 계정 모두 기본값은 false다. 이메일 소유권을 실제로 검증하기 전에는 true로 간주하지 않는다.
인증 완료만 true로 변경하며 비밀번호 재설정은 이 상태를 변경하지 않는다.
향후 이메일 인증을 요구하는 기능에서는 유효한 세션을 확인한 후 DB의 User.isEmailVerified를 검사한다.
JWT나 클라이언트가 보낸 상태를 신뢰하지 않는다. 기존 세션은 인증 전후 모두 유지된다.
동일 이메일 중복 가입은 기존 DB UNIQUE 및 HTTP 409 정책을 유지한다.

## API

### POST /auth/signup

기존 요청과 SessionResponseDTO를 유지한다. 계정/세션 트랜잭션이 완료된 후 인증 메일을 발송한다.
발송 제한, 설정 누락, Resend 실패 때문에 이미 생성된 계정/세션을 되돌리거나 실패 응답을 주지 않는다.
서버에는 민감 정보 없는 경고를 남긴다. 사용자는 재전송 endpoint로 복구할 수 있다.
실패 응답을 보고 다시 가입했다가 409를 받는 상황을 피하기 위한 정책이다.

### POST /auth/verify-email

요청: `{"token":"메일 링크의 64자리 토큰"}`

성공: HTTP 200, `{"message":"이메일 인증이 완료되었습니다."}`

잘못된 토큰, 만료, 재사용, 재발급으로 폐기된 토큰, 삭제된 사용자:
HTTP 400, `{"error":true,"reason":"유효하지 않거나 만료된 이메일 인증 토큰입니다."}`

로그인이 필요하지 않다. 토큰으로 이메일 소유권을 증명한다.
사용자 행을 잠근 뒤 토큰을 다시 조회하고 상태 갱신과 삭제를 같은 트랜잭션에서 수행한다.
동시 인증 요청도 단 하나만 성공한다. 이미 인증한 토큰은 다시 성공하지 않는다.
GET 요청은 인증 상태를 변경하지 않는다. 메일 검사기의 링크 방문으로 인증되는 것을 방지한다.

### POST /auth/resend-verification-email

요청: `{"email":"user@example.com"}`, 선택 헤더 `X-Client-ID`.

유효한 이메일 형식이면 계정 존재 여부, 인증 상태, 발송 제한 및 발송 실패와 무관하게:
HTTP 200, `{"message":"인증이 필요한 계정이면 이메일 인증 안내를 발송했습니다."}`

잘못된 이메일 형식은 기존 방식의 HTTP 400이다.
계정 조회 전에 기존 EmailService/EmailRateLimitService의 signUpVerification action을 소비한다.
없는 계정과 이미 인증된 계정에는 메일/토큰을 생성하지 않는다.
제한되면 기존 토큰을 그대로 유지한다. 회원가입 메일과 재전송, passwordReset은 recipient/client/IP/전체 한도를 공유한다.

## 토큰 및 재전송

AuthSession.randomToken()의 암호학적 난수 32바이트를 사용한다(256비트, hex 64자리).
DB에는 SHA-256 해시만 저장하고 유효 시간은 24시간이다.
`email_verification_tokens`는 user_id와 token_hash가 각각 UNIQUE이며 사용자 삭제 시 CASCADE한다.
새 토큰 생성 시 이전 토큰을 교체하므로 사용자당 최대 한 행만 남는다.
만료된 행은 인증에 사용할 수 없고 다음 재전송, 인증 완료 또는 탈퇴 시 정리된다.

재전송과 인증은 같은 사용자 잠금을 사용한다. 네트워크 발송은 DB 트랜잭션 밖에서 실행한다.
따라서 동시에 보낸 메일이 순서대로 도착한다는 보장은 없으며 가장 최근에 생성된 링크만 유효하다.
발송 실패 시 해당 발송의 토큰만 삭제한다(다른 재전송이 생성한 토큰은 삭제하지 않는다).
이전 토큰은 복원하지 않으므로 실패 후에는 다시 재전송해야 한다.

## 배포 설정

먼저 AddEmailVerificationMigration을 실행한다. 기존 migration 파일은 수정하지 않는다.
새 테이블과 `users.is_email_verified NOT NULL DEFAULT FALSE`를 추가한다.

`EMAIL_VERIFICATION_URL_BASE=https://your-frontend.example/verify-email`을 설정한다.
이는 사용자가 방문할 HTTPS 화면 URL이다. 기존 query parameter를 유지하고 token parameter를 추가한다.
해당 화면/앱은 토큰을 읽어 POST /auth/verify-email을 호출해야 한다.
이번 변경은 서버 인터페이스와 이메일 템플릿이며 프론트엔드/iOS 구현은 포함하지 않는다.

기존 RESEND_API_KEY, 발신자 설정 및 EMAIL_TRUST_RAILWAY_PROXY 설정은 재사용한다.
메일 발송 실패의 상세 응답, 이메일 주소, 링크, 원문 토큰을 서버 경고 로그에 넣지 않는다.

## 테스트

`swift test`에서 기존 PostgreSQL 인증 lifecycle과 함께 실행한다.
전용 TEST_DATABASE_NAME=waktrainer_test_auth 설정이 필요하다.
기존 스키마에서의 migration, 토큰 생성/해시/만료, 미인증 세션 유지, 잘못된 토큰,
재전송과 이전 토큰 폐기, 동시 인증/재사용 방지, 이미 인증됨/없는 계정,
공통 rate limit/만료 후 재허용, 탈퇴 CASCADE, 발송 실패 후 복구를 검증한다.
