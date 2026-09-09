# 이메일 변경

## API와 계정 정책

두 endpoint 모두 `Authorization: Bearer <accessToken>`과 JSON 요청을 사용한다.
기존 SessionResponseDTO/UserResponseDTO는 변경하지 않는다.

### POST /auth/request-email-change

```json
{"currentPassword":"현재 비밀번호","newEmail":"new@example.com"}
```

유효한 세션과 현재 비밀번호를 검증한다. 이메일 형식 검증, 비교와 저장은 signup/login과
동일하다. trim/lowercase를 새로 적용하지 않는다. limiter의 수신자 버킷 정규화만 기존대로 적용한다.
현재 이메일과 같으면 400, 다른 사용자가 이미 사용하면 409를 반환한다.
비밀번호 오류/폐기된 세션은 401, 잘못된 입력은 400이다.
인증된 사용자 요청이므로 중복 이메일에 대한 일반적인 409 안내는 허용한다.

성공: HTTP 200

```json
{"message":"새 이메일로 이메일 변경 인증 안내를 발송했습니다."}
```

실제 계정 이메일과 인증 상태는 바꾸지 않는다. 기존 이메일로 login, refresh, /auth/me가 계속 동작한다.
새 이메일은 예약되지 않는다. 인증 전에 다른 사람이 가입하거나 변경할 수 있으므로 완료 시 다시 확인한다.

`EmailService.withRequest`와 `EmailSending`을 통해 `emailChangeVerification` action으로 발송한다.
세션/입력 검증 후 공통 limiter를 소비하고 비밀번호 검증, 계정 조회, 토큰 생성을 수행한다.
비밀번호 오류와 중복 요청도 발송 quota를 소비한다. 선택 헤더 `X-Client-ID` 및 IP/recipient/action/global이
기존 [공통 제한](email-rate-limits.md)을 따른다. 제한 시 429와 일반적인 재시도 안내만 반환하며
기존 토큰은 유지한다. 남은 quota나 내부 버킷 정보는 반환하지 않는다.

### POST /auth/confirm-email-change

```json
{"token":"메일 링크의 64자리 토큰"}
```

요청을 시작한 사용자와 **동일한 사용자**의 유효한 Bearer 세션이 필요하다.
처음 요청한 세션과 같을 필요는 없다. 다른 브라우저/기기에서는 해당 계정으로 로그인한 뒤 완료한다.
토큰만으로 완료하지 않는다. GET 링크 방문은 상태를 변경하지 않으며,
화면/앱에서 사용자가 확인한 후 POST를 호출해야 한다.

성공: HTTP 200

```json
{"message":"이메일이 변경되었습니다. 다른 세션은 로그아웃되었습니다."}
```

한 트랜잭션에서 다음을 처리한다.

- 사용자 행 잠금 후 세션, 토큰 소유자·해시·만료를 검증한다.
- 중복 이메일을 다시 확인하고 `users.email` UNIQUE 제약으로 다른 사용자/동시 signup과의 충돌도 차단한다.
- 새 이메일을 저장하고 `isEmailVerified = true`로 설정한다. 이전 상태가 false여도 새 주소의 소유권이 증명되었으므로 true다.
- 이메일 변경 토큰, 기존 이메일 인증 토큰, 비밀번호 재설정 토큰을 삭제한다.
- 완료 요청 세션만 유지하고 다른 모든 세션을 폐기한다. 유지한 access/refresh token은 교체하지 않는다.

잘못된/만료된/재사용된/다른 사용자 토큰은 동일한 400 응답이다.
인증 누락/폐기된 세션은 401이다. 중복 충돌은 409이며 트랜잭션 전체가 롤백되어 계정과 세션을 유지한다.
같은 유효 세션으로 동시 완료하면 한 요청만 성공한다.
서로 다른 세션으로 경합하면 패배한 세션은 이미 폐기되어 401을 받을 수도 있다.

완료 후 `/auth/me`와 refresh 응답은 DB에서 새 이메일과 true 인증 상태를 읽는다.
클라이언트는 성공 후 `/auth/me`를 다시 조회해 표시 정보를 갱신한다.

## 토큰 수명과 경합

기존 AuthSession의 암호학적 난수 32바이트(256비트, hex 64자리)와 SHA-256을 재사용한다.
원문은 메일 링크에만 사용하고 DB에는 hash만 저장한다. 유효 시간은 30분이다.
`email_change_tokens`는 user_id와 token_hash에 각각 UNIQUE 인덱스를 가지며,
사용자 관계, pending_email, expires_at, created_at을 저장한다.
사용자당 최대 한 행이므로 새 요청이 DB에 성공적으로 생성되면 이전 링크는 무효화된다.
만료 토큰은 재요청 시 교체하고, 완료/비밀번호 변경·재설정/탈퇴 시 삭제한다.
활동이 없는 사용자의 만료 행은 최대 한 개 남으며 사용할 수 없다. 별도 전체 스캔이나 정리 작업은 추가하지 않는다.

발송 네트워크 호출은 DB 트랜잭션 밖에서 수행한다. 동시 발송의 도착 순서는 보장하지 않으며
가장 최근에 DB에 생성된 토큰만 유효하다. 발송 실패 시 해당 요청의 토큰 ID만 삭제한다.
이전 토큰은 복구하지 않는다. 기존 이메일/세션은 유지되고 사용자가 재요청할 수 있다.
제공자 실패는 기존 gateway의 502, 설정 오류는 500을 따른다. 비밀번호·토큰·링크·제공자 상세 오류는 새 로그에 기록하지 않는다.

## 다른 인증 동작과의 관계

비밀번호 변경/reset 성공 시 pending 이메일 변경을 취소한다. 실패한 시도는 취소하지 않는다.
탈퇴 시 외래 키 CASCADE가 pending 토큰을 삭제한다.
기존 [이메일 인증](email-verification.md)의 가입/재전송 동작과 세션 정책은 유지한다.

이메일 변경과의 경합을 막기 위해 login은 사용자 잠금 후 이메일을 재확인하고,
인증메일/reset 메일 생성도 잠금 후 현재 이메일을 재확인한다.
reset-password는 잠금 후 토큰을 재조회하여 이메일 변경 완료가 이미 폐기한 토큰을 사용할 수 없게 한다.

## Railway 배포

새 환경변수:

```text
EMAIL_CHANGE_URL_BASE=https://your-frontend.example/change-email
```

유효한 HTTPS 화면 URL이어야 하며 URL 사용자명/비밀번호를 허용하지 않는다.
기존 query parameter를 보존하고 token parameter는 교체한다.
링크 구성은 EmailVerificationService의 공통 함수를 재사용한다.
화면/iOS 앱은 로그인과 확인 UI 및 완료 POST 호출을 구현해야 한다. 이번 변경은 서버 API와 메일 템플릿이다.
기존 RESEND_API_KEY와 EMAIL_TRUST_RAILWAY_PROXY 설정을 재사용한다.

`AddEmailChangeMigration`을 기존 migration 마지막에 추가한다.
Railway production pre-deploy 명령은 그대로 사용한다.

```sh
./WakTrainerServer migrate --env production --yes
```

새 빈 테이블과 해당 테이블의 UNIQUE 인덱스/FK만 생성한다.
기존 users/session 데이터 수정, 사용자 테이블 backfill, 기존 인덱스 재생성은 없다.
FK 생성에 따른 짧은 테이블 잠금은 발생할 수 있으므로 무잠금 migration은 아니다.
기존 서버와 스키마가 호환되며 Fluent migration 기록에 따라 성공 후 재실행은 no-op이다.
수동으로 만든 동명 테이블 등 비정상 스키마는 자동 복구하지 않는다.
롤백은 새 테이블만 삭제하므로 pending 요청은 사라진다. 새 기능 사용 중에는 테이블을 먼저 삭제하지 않는다.
실제 production DB에는 이 작업에서 접속하거나 migration을 실행하지 않는다.

## 검증

전용 PostgreSQL `waktrainer_test_auth`에서 기존 스키마 업그레이드와 migration 재실행,
요청/비밀번호/중복 검증, hash 저장, 만료/재사용/소유자 검증, 동시 완료와 중복 주소 경합,
재요청, 공통 limiter 각 기준, 발송 실패 복구, me/refresh, 세션 폐기,
비밀번호 변경/reset 취소 및 탈퇴 CASCADE를 기존 auth 통합 테스트와 함께 검증한다.
실제 수신함 전달은 mock transport 테스트의 범위에 포함되지 않는다.
