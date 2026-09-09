# 보안 감사 로그

인증·보안 이벤트는 PostgreSQL `audit_logs`에 기록한다. 일반 debug/application log와 분리하며,
이번에는 조회 API를 제공하지 않는다. 운영 DB 권한이 있는 담당자만 조회한다.
감사 테이블은 변경 불가능한 외부 보관소가 아니므로 DB 관리자에 의한 변경까지 방지하지는 않는다.

## 이벤트와 의미

| event_type | 기록 시점 |
| --- | --- |
| signUpSucceeded | 사용자·세션 생성 커밋 후. 가입 인증메일 발송 실패와 무관 |
| loginSucceeded | 비밀번호 검증과 세션 발급 성공 후 |
| loginFailed | 로그인 401. 없는 계정과 비밀번호 오류 모두 invalidCredentials |
| refreshSucceeded | refresh rotation 커밋 후 |
| refreshRejected | refresh 401. invalidRefresh로 통일 |
| logout | 현재 세션 폐기 성공 후 |
| logoutOtherSessions | 현재 세션 외 폐기 성공 후 |
| logoutAll | 전체 세션 폐기 성공 후 |
| sessionRevoked | 특정 관리용 세션 삭제 성공 후 |
| passwordChanged | 비밀번호 변경과 세션 폐기 커밋 후 |
| passwordResetRequested | 유효한 forgot-password 요청의 기존 200 응답. 계정 존재·발송 여부를 의미하지 않음 |
| passwordResetSucceeded | 비밀번호 재설정 커밋 후 |
| emailVerificationSucceeded | 이메일 소유권 인증 커밋 후 |
| emailVerificationResendRequested | 재전송 API의 기존 200 응답. 발송 성공을 의미하지 않음 |
| emailChangeRequested | 변경 토큰 생성과 발송 gateway 호출 성공 후. 실제 수신함 도착 보장은 아님 |
| emailChangeSucceeded | 이메일 변경 및 기존 토큰·다른 세션 폐기 커밋 후 |
| accountWithdrawn | 사용자 삭제 커밋 후. user_id는 null |
| loginRateLimited | 로그인 429 |
| emailRateLimited | 공통 이메일 gateway에서 limiter가 발송 요청을 차단한 경우 |

`/auth/me`, 세션 목록 등 일반 조회는 기록하지 않는다. 위에 정의하지 않은 모든 실패/잘못된 JSON 요청을
포괄하는 access log 기능은 아니다. 이메일 차단은 기존 API에 따라 HTTP 200 또는 429일 수 있다.
차단된 비밀번호 재설정/재전송 요청에는 Requested와 emailRateLimited가 각각 남을 수 있다.
DB 오류·provider 오류 원문은 기록하지 않는다.

## 저장 스키마

- id: 이벤트 UUID
- event_type: 문자열. 코드의 AuditEventType enum으로 제한하여 기록하며 DB enum migration 없이 확장 가능
- occurred_at: 이벤트를 기록하려는 시점의 UTC 시각. 동시 작업의 커밋 순서를 보장하는 sequence는 아님
- user_id: nullable 사용자 FK, ON DELETE SET NULL
- session_management_id: nullable 관리용 세션 UUID. 토큰이나 JWT sid가 아니며 세션 FK는 없음
- email_hash / ip_hash / client_id_hash: 필요한 경우의 HMAC-SHA256 식별값
- metadata: 제한된 typed JSONB
- dedup_key / minute_bucket: 잡음 이벤트 중복 억제용 값. 일반 성공 이벤트는 null

metadata에는 enum reasonCode/endpoint/action과 숫자 statusCode만 허용한다.
성공 여부는 event_type으로 표현하므로 중복 Boolean 필드를 두지 않는다.
sessionRevoked의 session_management_id는 폐기한 대상이며, 다른 세션 이벤트에서는 요청/발급 세션이다.
비밀번호 재설정과 일반 이메일 인증처럼 세션이 필요 없는 흐름은 관리용 ID가 없을 수 있다.

로그인 실패는 계정이 존재하더라도 user_id를 null로 둔다. 잡음 이벤트의 user_id와 session_management_id도
null로 기록하여 계정 존재 여부를 노출하지 않는다. 필요하면 정규화된 email_hash로 실패들을 연관 분석한다.

## 식별값과 민감정보

`AUDIT_HASH_KEY`에 충분히 긴 별도 난수 키를 설정한다. JWT_SECRET이나 provider 키를 재사용하지 않는다.
모든 서버 인스턴스에 같은 키를 설정해야 동일 source의 DB 중복 억제가 일관되게 동작한다.
이 키는 HMAC-SHA256용으로만 사용하며 DB에 저장하거나 출력하지 않는다.
키가 없거나 빈 문자열이면 hash 필드는 생략하고 이벤트 기록은 유지한다. 키 변경은 재시작 후 적용된다.
키를 변경하면 같은 입력도 다른 해시가 되므로 이전 이력과의 해시 기반 연결이 끊어진다.

해시 입력에는 `audit:v1:email:`, `audit:v1:ip:`, `audit:v1:client:` 접두어로 도메인을 구분한다.
이메일은 trim/lowercase한 뒤 해시하며 계정 비교·저장 정책 자체는 바꾸지 않는다.
client ID는 기존과 같은 단일 X-Client-ID, trim 후 비어 있지 않은 최대 128 UTF-8 바이트만 사용한다.
IP는 기존 EmailRateLimitService.clientIP의 Railway 신뢰 정책을 재사용하며 알 수 없는 주소는 null이다.
`EMAIL_TRUST_RAILWAY_PROXY=true`는 신뢰된 Railway ingress에서만 설정한다.
로그인 limiter 자체의 IP 정책은 바꾸지 않는다. 따라서 프록시 신뢰 옵션을 켜면 audit IP와 로그인 limiter의
직접 연결 IP 기준이 다를 수 있다.

단순 SHA-256과 달리 키 없는 사전 대입을 어렵게 하지만 해시와 UUID도 개인정보 연관성이 있는 가명 식별값이다.
접근 권한과 보존 기간을 적용해야 하며 익명 데이터로 간주하지 않는다.

기록하지 않는 값:

- 이메일/IP/clientId 원문
- password, access/refresh/reset/verification token, token hash, JWT, API key, secret
- deviceName, User-Agent, 요청 body/header 전체, URL/query, 오류 문자열

Request context에는 이미 해시된 이메일과 허용된 UUID/enum만 전달한다. 미들웨어는 body나 JWT를 재해석하지 않는다.
감사 DB의 logger와 tracing은 비활성화하여 SQL 바인딩 및 DB 오류 상세가 일반 로그에 섞이지 않도록 한다.
감사 쓰기 실패 경고는 고정된 문장만 사용하며 프로세스당 최대 분당 한 번 출력한다.
기존 application log는 별도이므로 운영에서는 요청 body·Authorization·URL 토큰을 기록하는 외부 프록시/수집 설정도 피해야 한다.

## source별 분 단위 억제

다음 키를 만들고 `(dedup_key, minute_bucket)` UNIQUE로 PostgreSQL에서 중복을 억제한다.
minute_bucket은 DB CURRENT_TIMESTAMP 기준 1분이다. 분 경계에서는 양쪽 분에 각각 기록될 수 있다.

| 이벤트 | source 구성 |
| --- | --- |
| loginFailed | eventType + emailHash + ipHash |
| refreshRejected | eventType + ipHash |
| loginRateLimited | eventType + ipHash |
| emailRateLimited | eventType + action + ipHash |
| passwordResetRequested | eventType + emailHash + ipHash |
| emailVerificationResendRequested | eventType + emailHash + ipHash |

서로 다른 source를 하나의 전역 이벤트로 합치지 않는다. 같은 IP의 이메일 차단은 수신자를 바꾸더라도
같은 action이면 같은 분에 하나만 기록한다. clientId는 위 bucket에 사용하지 않아 임의 헤더 변경만으로
중복 억제를 우회하지 못하게 한다. dedup_key는 이미 가명처리한 해시와 고정 label을 SHA-256 처리한 값이다.
키가 없거나 IP를 알 수 없어 source 정보가 없으면 해당 자리를 unknown으로 취급하므로 구분 능력이 줄어든다.
원문을 대신 저장하지 않는다.

프로세스별 최대 4,096개 cache가 반복 DB 접근을 줄이고 DB UNIQUE가 여러 인스턴스의 중복을 막는다.
Cache는 로컬 분 시각을 사용하므로 서버 시계 차이에 따라 경계 근처의 일부 이벤트가 추가로 억제될 수 있다.
이는 카운터 집계가 아닌 최초 이벤트 표본이며 정확한 시도 횟수로 해석하면 안 된다.

source가 계속 바뀌면 서로 다른 감사 행이 생성된다. 전역 1건으로 합치지는 않으며, 대신 프로세스별
동시 감사 쓰기를 4개로 제한하고 초과 기록은 best-effort로 생략한다. 별도 풀의 짧은 대기 timeout과
DB timeout으로 인증 연결 점유를 제한한다. 이 제한은 새 API rate limiter나 전체 디스크 사용 상한이 아니다.
운영 수집량을 관찰하고 다음 maintenance 단계의 보존 기간 삭제를 적용해야 한다.

## 실패 격리와 트랜잭션

AuthController는 중앙 AuditLogMiddleware를 등록하고 서비스/세션 코드에서 최소 context만 제공한다.
미들웨어는 handler의 성공 반환 이후 기록하므로 정상 경로의 비즈니스 transaction은 이미 커밋되어 있다.
실패/rollback된 작업에 성공 이벤트를 생성하지 않는다. audit INSERT는 별도의 best-effort transaction이다.

기존과 같은 PostgreSQL에 별도 `audit` 연결 풀을 둔다. event loop당 최대 1개 연결, 풀 대기 250ms,
statement_timeout 250ms, lock_timeout 100ms를 적용한다. 개별 SQL timeout이며 요청 전체의 엄격한 시간 상한은 아니다.
마이그레이션은 기존 기본 DB 연결로 실행한다. 새 audit 풀은 기본 인증 풀을 대체하지 않는다.

저장 오류는 인증 결과를 변경하지 않으며, 실패 후 5초 동안 해당 recorder의 추가 쓰기를 쉬어 반복 장애 부하를 줄인다.
과부하·timeout·쿨다운 중의 이벤트는 누락될 수 있다. 별도 무제한 queue나 detached task, 재시도 scheduler는 없다.
비즈니스 커밋 직후 프로세스가 종료되어도 이벤트가 누락될 수 있으므로 완전한 전달 보장이나 규제용 원장으로 취급하지 않는다.

회원탈퇴와 audit INSERT가 겹치면 사용자 KEY SHARE SKIP LOCKED 잠금 및 FK가 연결을 조정한다.
사용자가 이미 삭제되었거나 다음 인증 transaction에 잠겨 있으면 해당 이벤트는 user_id=null로 저장한다.
따라서 user_id=null만으로 계정이 없었다고 판단할 수 없다. 연결하지 못한 사용자 UUID는 다른 필드에 복사하지 않는다.
기존 이력은 ON DELETE SET NULL로 유지하며 accountWithdrawn은 처음부터 user_id=null이다.
관리용 ID와 해시는 보존될 수 있으므로 완전한 익명화는 아니다. FK 처리 자체는 탈퇴 transaction에 포함된다.

## 보존과 운영 조회

보존 기준은 90일이다. **이번 단계에서는 자동 삭제하지 않는다. 5번 DB maintenance 작업에서 구현한다.**
그 전에는 아래 SQL 등 승인된 운영 절차로 정리해야 하며, 90일이 지나도 저절로 삭제되지는 않는다.
다른 인증 토큰 테이블의 정리 정책과는 별개다.

최근 이벤트 조회 (운영 DB 권한 필요):

```sql
SELECT occurred_at, event_type, user_id, session_management_id, metadata
FROM audit_logs
ORDER BY occurred_at DESC
LIMIT 100;
```

이벤트 종류별 저장 행 수 (차단 시도 횟수가 아님):

```sql
SELECT event_type, count(*) AS recorded_events
FROM audit_logs
WHERE occurred_at >= CURRENT_TIMESTAMP - INTERVAL '1 day'
GROUP BY event_type;
```

90일 초과 행의 제한된 개수 정리 (트랜잭션을 짧게 유지하며 필요 시 반복):

```sql
DELETE FROM audit_logs WHERE id IN (
    SELECT id FROM audit_logs
    WHERE occurred_at < CURRENT_TIMESTAMP - INTERVAL '90 days'
    ORDER BY occurred_at
    LIMIT 1000 FOR UPDATE SKIP LOCKED
);
```

## Migration과 검증

`CreateAuditLogMigration`을 기존 migration 마지막에 추가한다.
새 테이블과 occurred_at / (user_id, occurred_at) / (event_type, occurred_at) 및 중복 억제용 인덱스만 생성한다.
users 데이터 backfill과 기존 세션/토큰 변경은 없다. FK 생성의 짧은 잠금 대기는 5초로 제한한다.
prepare는 transaction이므로 DDL 실패 시 해당 변경은 rollback한다. Fluent에 성공 기록된 migration은 재실행하지 않는다.
revert는 audit 테이블을 삭제하여 이력을 잃으므로 운영에서는 보존 정책을 확인한 뒤 수행해야 한다.
기존 사용자/인증 테이블은 보존한다.

Railway 기존 pre-deploy 명령:

```sh
./WakTrainerServer migrate --env production --yes
```

새 코드 실행 전에 migration을 완료하고 AUDIT_HASH_KEY를 운영 환경에 설정한다.
이 작업에서 production DB에 migration이나 삭제 SQL을 실행하지 않는다.

전용 PostgreSQL 통합 테스트는 이벤트 생성, 민감값 미포함, 로그인 실패 user_id=null,
탈퇴 후 FK null 처리, rollback 시 성공 이력 없음, audit INSERT 장애 시 인증 유지,
source별 분 bucket, 다른 action/source 분리, 동시 중복 INSERT 및 upgrade/revert를 검증한다.
기존 인증·이메일·세션 관리 시나리오도 함께 실행한다.
