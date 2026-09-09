# 세션 관리

## 식별자와 토큰

`refresh_tokens` 행이 JWT의 `sid`에 연결된 인증 세션이다. access JWT의 `sub`/`sid`/`exp`,
opaque refresh token, SHA-256 저장, refresh 시 기존 행 삭제와 새 행/토큰 발급은 유지한다.

목록의 `id`는 별도의 **관리용 세션 ID**다. 로그인/signup마다 생성되며 refresh 때 계승된다.
JWT `sid`는 계속 교체되므로 두 ID를 서로 바꾸어 사용하면 안 된다.
클라이언트는 목록에서 받은 `id`를 삭제 API에 사용하고 JWT를 해석해 삭제 대상을 만들지 않는다.
관리용 ID는 인증 수단이 아니다. 모든 작업은 Bearer 세션과 사용자 소유권을 검증한다.
같은 기기에서 두 번 로그인하면 두 세션으로 표시된다. deviceName으로 세션을 합치지 않는다.

## 목록과 metadata

### GET /auth/sessions

Bearer 인증이 필요하며 현재 사용자의 미만료 세션만 반환한다.
성공 HTTP 200, `{"sessions":[...]}`. 각 항목의 공개 필드는 다음과 같다.

| 필드 | 의미 |
| --- | --- |
| `id` | refresh 후에도 유지되는 관리용 UUID |
| `createdAt` | **현재 refresh 행** 생성 시각. refresh 때 변경 |
| `startedAt` | 관리용 세션의 로그인/signup 시작 시각. refresh 때 유지 |
| `expiresAt` | 현재 refresh token의 만료 시각 |
| `lastRefreshedAt` | 마지막 refresh 성공 시각. 로그인 직후에는 없음 |
| `isCurrent` | 현재 행 ID와 요청 JWT sid가 같은지 여부 |
| `deviceName` | 선택적 기기 이름 |

날짜는 기존 Vapor JSON 날짜 인코딩(초 단위 ISO-8601)을 사용한다. 값이 없는 optional 필드는 생략될 수 있다.
목록은 현재 행 생성 시각 내림차순, 행 ID 오름차순이다. refresh 직후 정렬 위치는 바뀔 수 있다.
refresh token 원문/해시, 사용자 ID, clientId/IP/User-Agent는 목록에 노출하지 않는다.

signup/login에 선택 헤더 `X-Device-Name`을 보낼 수 있다.
단일 헤더, 최대 128 UTF-8 바이트, 제어문자 없음 조건을 확인하고 앞뒤 공백을 제거한다.
빈 값·누락·중복·잘못된 값은 무시한다. 기존 클라이언트의 로그인은 실패하지 않는다.
refresh에서는 기존 이름을 유지한다. 헤더를 이용한 이름 변경이나 인증은 하지 않는다.
이 값은 클라이언트가 주장한 표시용 문자열이므로 UI는 텍스트로 렌더링하고 신뢰된 기기 증명으로 취급하지 않는다.
세션 metadata에는 clientId/IP/User-Agent를 수집하지 않는다. 이메일 limiter의 X-Client-ID 정책은 그대로다.

일반 API 사용마다 lastUsedAt UPDATE를 추가하지 않는다. lastRefreshedAt은 실제 마지막 API 사용 시각이
아니며 refresh 성공 시 새 행에만 기록한다. 사용자 활동 추적 및 DB 쓰기 부하를 최소화한다.

## 세션 폐기

모두 `Authorization: Bearer <accessToken>`이 필요하다.

| API | 동작 | 성공 응답 (HTTP 200) |
| --- | --- | --- |
| `DELETE /auth/sessions/:sessionID` | 지정한 관리용 세션 폐기. 현재 세션도 허용 | `{"message":"세션이 로그아웃되었습니다."}` |
| `POST /auth/logout-other-sessions` | 요청 JWT sid의 현재 세션만 유지 | `{"message":"다른 모든 세션이 로그아웃되었습니다."}` |
| `POST /auth/logout-all` | 현재 세션 포함 전부 폐기 | `{"message":"모든 세션이 로그아웃되었습니다."}` |

없는 ID와 다른 사용자 소유 ID는 동일한 404와 `세션을 찾을 수 없습니다.`를 반환한다.
잘못된 UUID 형식은 400이다. 인증 누락/폐기/만료된 Bearer는 401이다.
특정 삭제는 이미 삭제된 대상에 대해 404를 반환한다. 만료 행이 아직 남아 있으면 본인 소유인 경우 삭제할 수 있다.
이전에 폐기한 현재 세션으로 재요청하면 401이다.
다른 세션이 없어도 logout-other-sessions는 성공한다.
폐기한 행의 access/refresh token은 이후 검증에서 실패한다. 이미 인증 검증을 통과해 진행 중인 요청을
소급 취소하는 기능은 아니다. 일반적인 로그인은 계속 허용되므로 폐기 후 새 로그인은 별도 세션을 생성한다.

## 동시성

목록과 폐기는 기존 AuthSession.lockUser와 동일한 사용자 행 잠금/트랜잭션을 사용한다.
특정 폐기는 잠금 후 **user_id + 관리용 ID**로 조회·삭제한다. 다른 계정의 ID로 삭제할 수 없다.

- 대상 refresh보다 폐기가 먼저 완료되면 refresh는 토큰 재조회에서 실패한다.
- 대상 refresh가 먼저 완료되면 폐기는 관리용 ID로 교체된 행을 찾아 삭제한다.
- logout-all이 성공하면 그 시점까지의 모든 세션이 삭제된다. 앞서 성공한 refresh의 새 토큰도 사용할 수 없다.
- 호출 세션 자체의 refresh가 먼저 완료되면 기존 Bearer sid가 폐기되므로 관리 API는 401일 수 있다.
  이때 클라이언트는 refresh 결과로 받은 새 Bearer로 다시 요청한다. 관리 작업과 자체 refresh는 클라이언트에서 순서를 맞추는 것이 좋다.

로그인/refresh/logout/change-password/reset-password/email change가 같은 잠금 규칙을 사용한다.
기존 정책은 그대로 유지한다: logout은 현재 세션만, 비밀번호 변경/reset은 모든 세션,
이메일 변경 완료는 현재 세션만 유지한다. 이메일 인증은 세션을 폐기하지 않는다.
세션 관리 API는 이메일 변경·인증·비밀번호 재설정 토큰의 별도 수명 정책을 변경하지 않는다.

## 기존 데이터와 정리

기존 행의 metadata는 null이다. 관리용 ID가 없으면 그 행 ID를 사용하고 다음 refresh에 계승한다.
기존 세션의 실제 최초 로그인 시각은 복구할 수 없으므로 최초 전환 시 남아 있는 createdAt을 startedAt으로 사용한다.
createdAt까지 없는 기존 행은 startedAt을 모르는 상태로 유지한다. 새 로그인부터 정확한 시작 시각을 기록한다.

세션 발급 및 목록 조회 시 해당 사용자의 만료 행을 최대 100개씩 삭제한다.
다른 사용자의 행은 건드리지 않는다. `(user_id, expires_at, id)` 인덱스로 조회 범위를 제한한다.
100개 이상 남아 있어도 목록에서는 모든 만료 행을 제외하고 인증에도 사용할 수 없다.
활동 없는 계정의 만료 행은 남을 수 있다. 전체 정리는 향후 maintenance 작업 대상으로 두며 scheduler는 추가하지 않는다.
refresh에서 소비한 이전 행은 기존처럼 즉시 삭제하므로 사용한 refresh token 이력을 누적 저장하지 않는다.

## Railway migration

환경변수 추가는 없다. 기존 pre-deploy 명령을 유지한다.

```sh
./WakTrainerServer migrate --env production --yes
```

기존 migration 뒤에 다음을 순서대로 적용한다.

1. `AddSessionMetadataMigration`: nullable management_id/started_at/last_refreshed_at/device_name 컬럼 추가.
2. `IndexSessionUserExpiryMigration`: 새 복합 인덱스를 CREATE INDEX CONCURRENTLY로 생성.

기존 created_at을 중복 추가하거나 변경하지 않는다. 기존 토큰·행 ID·만료·세션 데이터에 대한 backfill이나 삭제는 없다.
컬럼 추가는 짧은 테이블 잠금이 필요하며 트랜잭션 내 lock_timeout=5s로 잠금 대기가 길면 실패한다.
이 경우 pre-deploy를 다시 실행한다. 성공한 migration은 Fluent 기록으로 재적용되지 않는다.

인덱스 migration은 트랜잭션 밖에서 실행해야 한다. 현재 Fluent migrator가 prepare를 외부 트랜잭션으로
감싸지 않는 구조를 사용한다. 인덱스 생성 중 일반 쓰기를 차단하지 않지만 DB I/O와 기존 트랜잭션 대기 비용은 있다.
중단된 concurrent build의 invalid 인덱스는 다음 실행에서 제거 후 재생성한다.
인덱스 생성만 완료되고 migration 기록이 실패한 경우에도 IF NOT EXISTS로 재실행할 수 있다.

역순 revert는 인덱스와 새 컬럼만 제거하며 토큰/세션 행을 보존한다. metadata는 사라진다.
새 서버 실행 중에 컬럼을 먼저 제거하면 안 된다. 구버전 서버는 추가 컬럼을 무시할 수 있지만 refresh 때
관리용 ID를 계승하지 않으므로 새 세션 관리 API를 사용하기 전에 모든 서버 인스턴스를 업데이트해야 한다.
이 작업에서는 production DB에 접속하거나 migration을 적용하지 않는다.

## 테스트

전용 PostgreSQL `waktrainer_test_auth`에서 upgrade/revert/재적용, 기존 행 보존,
활성 목록/현재 세션/타인 격리, 시각과 metadata 계승, 안정적인 ID로 후속 세션 삭제,
현재/다른/전체 세션 폐기와 access/refresh 거부, 만료 데이터의 사용자별 제한 정리를 검증한다.
refresh와 특정 폐기·다른 세션 폐기·전체 폐기를 동시에 실행하며, 기존 인증 및 이메일 변경 테스트도 함께 실행한다.

```sh
swift test --disable-sandbox
git diff --check
```
