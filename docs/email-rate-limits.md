# 공통 이메일 발송 제한

사용자가 트리거하는 이메일은 `EmailService.withRequest(to:action:on:prepare:)`로 발송한다.
실제 Resend transport는 같은 파일의 private 구현이고, 테스트용 `EmailSending`도 서비스 안에 주입한다.
새 action은 `EmailAction(rawValue:)`로 확장한다. 계정 조회·토큰 생성은 반드시 prepare 안에서 수행하고
발송할 `EmailMessage`를 반환한다. 계정이 없으면 nil을 반환한다. 한 번의 허용으로 한 수신자에게 최대 한 통만 보낸다.

## 정책과 저장

`EmailRateLimitPolicy` 한 곳에서 정책을 관리한다.

| 기준 | 기본 한도 |
| --- | --- |
| recipient (모든 action 합산) | 5회 / 10분 |
| X-Client-ID (모든 action 합산) | 10회 / 10분 |
| IP (모든 action 합산) | 20회 / 10분 |
| action (모든 수신자 합산) | 500회 / 10분 |
| 전체 (모든 action/서버 합산) | 1,000회 / 10분 |
| passwordReset + recipient 추가 제한 | 10회 / 1시간 |

전체 한도는 실제 발송보다 보수적인 **유효한 발송 요청 수** 제한이다.
없는 계정, 차단 요청, 발송 실패도 모든 해당 기준에 계산하므로 계정 유무나 Resend 결과에 따라
잔여 한도가 달라지지 않는다. 배포 규모에 맞춰 전체/action 한도를 조정한다.
카운터는 한도 + 1에서 포화하며 차단 요청이 만료 시간을 연장하지 않는다.
고정 윈도우이므로 경계 전후에는 짧은 시간에 최대 두 윈도우 분량이 허용될 수 있다.

recipient는 trim/lowercase한 뒤 SHA-256 처리한다. 이는 제한 버킷용이며 실제 계정 조회는 그대로 유지한다.
clientId와 IP도 SHA-256으로 저장하며 원문을 제한 테이블에 저장하지 않는다.
clientId는 선택적이고 변경/위조 가능한 abuse 신호다. 단일 헤더의 비어 있지 않은 최대 128 UTF-8 바이트만 사용한다.
없거나 유효하지 않아도 email/IP/action/전체 제한은 적용한다. iOS 변경은 필요하지 않다.

독립된 `email_rate_limits` 테이블은 기존 LoginRateLimit의 SQL 기반 migration 구조를 따른다.
별도 Fluent Model 없이 SQL 카운터를 사용한다. PostgreSQL UPSERT와 트랜잭션으로 여러 인스턴스의
요청을 직렬화하고 DB 시간을 사용한다. 요청마다 만료 인덱스를 통해 최대 100개를
`FOR UPDATE SKIP LOCKED`로 정리한다. 트래픽이 없을 때 남은 만료 데이터는 다음 요청 시 정리된다.
발송 전에 migration을 실행해야 한다. 기존 login 제한 테이블과 정책은 변경하지 않는다.

forgot-password는 제한 시에도 기존 HTTP 200 및 동일 message를 반환한다.
차단되면 계정 조회, 기존 reset token 삭제, 새 token 생성, transport 호출이 모두 생략된다.
일반적인 새 기능은 서비스의 false 반환을 자체 기존 응답 정책에 맞춰 처리한다.
기존 설정 오류/Resend 실패 응답과 토큰 정리 동작은 유지한다.

## Railway의 IP 신뢰 경계

기본은 Vapor `remoteAddress.ipAddress`이고 IP가 없으면 공통 unknown 버킷이다.
임의 `X-Forwarded-For`나 `Forwarded`는 사용하지 않는다.
[Railway 공식 문서](https://docs.railway.com/networking/public-networking/specs-and-limits)는
클라이언트 IP 헤더로 `X-Real-IP`를 제공한다고 명시한다.

`EMAIL_TRUST_RAILWAY_PROXY=true`는 외부 요청이 신뢰하는 Railway edge를 통해서만 도달하고
해당 헤더의 덮어쓰기 정책을 확인한 배포에 한해 설정한다. 이 설정은 자동 활성화하지 않는다.
활성화하면 단일 유효 IP 형식의 X-Real-IP를 정규화하여 사용하고, 누락/잘못된 값은 remoteAddress로 돌아간다.
직접 접속 가능한 배포에서는 활성화하지 않는다. 기본값에서 프록시 뒤 요청은 프록시 IP 한도를 공유한다.
IP와 clientId 어느 쪽도 인증 정보로 사용하지 않는다. 기존 login IP 정책은 유지한다.

## 검증

`swift test`의 PostgreSQL 인증 통합 시나리오에 이메일 제한 검증을 포함한다.
기존처럼 TEST_DATABASE_NAME=waktrainer_test_auth 전용 DB가 필요하다.
수신자/clientId/IP, action/전체, 만료, 병렬 요청, 해시 저장, proxy 설정,
계정 유무와 무관한 응답 및 차단 시 토큰 유지 동작을 확인한다.
