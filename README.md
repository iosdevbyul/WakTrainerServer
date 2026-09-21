# WakTrainerServer

WakTrainer 앱 전용 백엔드의 초기 기반입니다. Swift 6.3, Vapor 4, Fluent,
PostgreSQL 16을 사용하며 인증 및 운동 도메인은 포함하지 않습니다.

## 로컬 실행

Swift 6.3 이상과 Docker Compose v2가 필요합니다.

```sh
cp .env.example .env
# .env의 DATABASE_PASSWORD를 로컬 전용 값으로 변경하세요.
docker compose up -d db
swift build
swift run WakTrainerServer serve --hostname 127.0.0.1 --port 8081
```

프로젝트 루트에서 실행하면 Vapor가 `.env`를 읽습니다. 기존 인증 서버와의
포트 충돌을 줄이기 위해 PostgreSQL 호스트 포트는 5433, HTTP 예시는 8081입니다.

```sh
curl --fail http://127.0.0.1:8081/health
# {"status":"ok"}
```

`/health`는 인증이나 DB 조회 없이 JSON을 반환하는 liveness 엔드포인트입니다.
DB 준비 상태를 보장하지 않습니다. Fluent 연결 풀은 처음 DB를 사용할 때
연결하므로, 서버 부팅과 DB 연결은 별도로 검증합니다.

## DB 설정

| 환경변수 | 기본값 | 설명 |
| --- | --- | --- |
| PORT | 8080 | HTTP 바인딩 포트 (Railway 주입값 사용) |
| DATABASE_URL | 없음 | 지정하면 개별 DB 설정보다 우선 |
| DATABASE_HOST | development: 127.0.0.1 | production에서는 명시 필수 |
| DATABASE_PORT | 5432 | DB 포트; 예제 .env는 로컬 매핑 5433 |
| DATABASE_USERNAME | development: waktrainer | production에서는 명시 필수 |
| DATABASE_PASSWORD | 없음, 필수 | 빈 값도 허용하지 않음 |
| DATABASE_NAME | development: waktrainer | production에서는 명시 필수; 인증 서버와 별도 DB |
| DATABASE_TLS | 아래 설명 참조 | disable 또는 require; URL의 TLS 설정도 덮어씀 |

HTTP는 기본적으로 `0.0.0.0:$PORT`에 바인딩합니다. 로컬에서 명시한 `--hostname`,
`--port` CLI 옵션은 이 기본 설정을 덮어씁니다. Docker 기본 명령에는 고정 포트가 없습니다.

`DATABASE_URL`은 `postgres://` 또는 `postgresql://` URL이며 사용자, 비밀번호,
호스트, DB 이름이 필요합니다. 잘못된 URL은 로컬 설정으로 fallback하지 않고 실패하며
오류 메시지에 URL/비밀번호를 포함하지 않습니다. 개별 DB 설정은 URL이 없을 때만 사용합니다.
URL에서 `sslmode`/`tlsmode`를 지정할 수 있으며 기본값은 드라이버의 `prefer`입니다.
개별 DB 설정의 기본 TLS는 development/testing에서 `disable`, production에서 `require`입니다.
`DATABASE_TLS`를 명시하면 양쪽 모두에 최우선 적용합니다. `require`는 인증서를 검증합니다.

Fluent의 기본 DB 식별자는 `.psql`입니다. 모델과 migration은 아직 없습니다.
Compose는 프로젝트 전용 named volume을 만들며 기존 인증 서버 볼륨을 사용하지 않습니다.
Compose의 app은 DB 컨테이너에 내부 포트 5432로 연결합니다.
외부 배포에서는 비밀 관리 시스템을 통해 비밀번호를 제공하고 TLS를 설정하세요.

## 테스트

```sh
swift test
# DB 컨테이너를 실행한 후 실제 연결까지 검증:
RUN_DATABASE_TESTS=1 swift test
```

일반 테스트는 DB 없이 health 응답, 부팅/종료, 잘못된 DB 설정을 검증합니다.
DB 연결 테스트는 `RUN_DATABASE_TESTS=1`일 때 실행되며 연결 획득 실패 시 실패합니다.
`.env`는 로컬 환경을 위한 파일입니다. 통합 테스트가 다른 DB를 향하지 않도록
테스트 대상 환경변수를 확인하세요. 현재 통합 테스트는 데이터를 변경하지 않습니다.

## Docker

```sh
docker compose --profile app up --build -d
curl --fail http://127.0.0.1:8081/health
docker compose --profile app logs app
docker compose --profile app down
```

기본 `docker compose up -d`는 PostgreSQL만 실행합니다. `app` profile은 서버도
실행합니다. 서버 이미지는 Swift 빌드 단계와 Ubuntu 런타임 단계로 나누고
비루트 사용자로 실행합니다. `.env`는 이미지에 포함하지 않습니다.
`down`은 DB 데이터를 유지합니다. DB 초기 사용자/비밀번호 설정은 빈 볼륨의
최초 초기화에만 적용됩니다.

## CI 및 책임 경계

GitHub Actions는 PR 및 main/bootstrap 브랜치 push에서 Swift 6.3 Linux
컨테이너와 PostgreSQL 16 service를 사용합니다. 고정된 Package.resolved로
의존성을 해결하고 `swift build`, `swift test`를 실행하며 DB 연결 테스트도 켭니다.
추가 단계에서 `DATABASE_URL` 방식의 실제 연결도 같은 테스트 바이너리로 확인합니다.

로그인, 로그아웃, 회원가입, 토큰 발급/갱신, 비밀번호 재설정, 세션 관리는
별도 공용 TrisAuthenticationServer의 책임입니다. 향후 이 서버는 발급된
Access Token을 검증해 사용자를 식별할 예정이며 이번 단계에는 구현하지 않았습니다.
User DB 모델, JWT, Workout/Routine/Exercise/Statistics, iOS 모델 패키지 의존성도 없습니다.


## Railway 배포 준비 (아직 실제 배포하지 않음)

독립 WakTrainerServer 저장소 루트를 배포 소스로 사용합니다. Railway는 루트의
[Dockerfile을 자동 감지](https://docs.railway.com/builds/dockerfiles)합니다.
`docker-compose.yml`은 로컬 개발용이고 Railway에서 실행하는 파일이 아닙니다.

### 서비스 설정

| 설정 | 값 |
| --- | --- |
| Root Directory | 저장소 루트 `/` |
| Builder | Dockerfile (자동 감지), 파일 `Dockerfile` |
| Custom Build Command | 비워둠 |
| Custom Start Command | 비워둠; Docker ENTRYPOINT/CMD 사용 |
| Healthcheck Path | `/health` |
| Healthcheck Timeout | 기본 300초로 시작 |
| Pre-deploy Command | Phase 1에서는 비워둠 |
| PORT | Railway 자동 주입값 사용; 수동 고정 불필요 |

Docker는 `serve --env production --hostname 0.0.0.0`으로 실행되며 앱이 PORT를 읽습니다.
`EXPOSE 8080`은 이미지 설명용 기본값이며 실제 바인딩을 8080으로 강제하지 않습니다.
HTTP 접근이 필요하면 Railway Networking에서 도메인을 연결합니다.

### Railway 환경변수

같은 Railway 프로젝트/환경의 PostgreSQL 서비스를 `Postgres`라는 이름으로 만들었다면
앱 서비스 Variables에서 아래와 같이 연결합니다. 실제 서비스 이름이 다르면 참조를 바꿉니다.

```text
DATABASE_URL=${{Postgres.DATABASE_URL}}
DATABASE_TLS=disable
LOG_LEVEL=info
```

위 `DATABASE_TLS=disable` 예시는 **Railway private network의 내부 DB 주소**를 사용하는
경우입니다. [Railway private network](https://docs.railway.com/networking/private-networking)는
WireGuard로 서비스 간 트래픽을 암호화합니다. 공개 DB 주소에 이 설정을 그대로 적용하지 마세요.
외부 DB에는 신뢰 가능한 서버 인증서와 `DATABASE_TLS=require`를 사용합니다.
URL의 TLS 옵션을 그대로 쓰려면 `DATABASE_TLS`를 제거합니다. 드라이버는 TLS 사용 시
인증서를 검증하므로 DB의 인증서/호스트 구성이 그에 맞아야 합니다.

`DATABASE_URL`을 쓰면 별도의 `DATABASE_PASSWORD` 등은 필요하지 않습니다.
대신 개별 변수를 쓰려면 다음을 앱 서비스에 설정합니다.

```text
DATABASE_HOST=${{Postgres.PGHOST}}
DATABASE_PORT=${{Postgres.PGPORT}}
DATABASE_USERNAME=${{Postgres.PGUSER}}
DATABASE_PASSWORD=${{Postgres.PGPASSWORD}}
DATABASE_NAME=${{Postgres.PGDATABASE}}
DATABASE_TLS=disable
```

이 역시 내부 DB 주소 기준입니다. [PostgreSQL 연결 변수 문서](https://docs.railway.com/databases/postgresql)를
참고하세요. `.env`를 Railway에 업로드하지 않습니다. 실제 비밀번호/URL은 Railway Variables에만
저장하고 Docker build arguments나 저장소에 넣지 않습니다. 저장소에는 로컬/CI용 예시 값만 있습니다.
Docker 빌드는 DB 접속이나 비밀 값 없이 실행됩니다.

### Migration 전략

Phase 1에는 모델/migration이 없으므로 pre-deploy 명령을 설정하지 않습니다.
앱 부팅과 Docker build에서도 migration을 자동 실행하지 않습니다.
도메인 migration을 도입하는 단계에서 `app.migrations.add(...)`로 등록하고
Railway Pre-deploy Command를 다음으로 설정합니다.

```sh
/app/WakTrainerServer migrate --yes --env production
```

동일 이미지에서 앱 실행 전에 한 번 실행하며 여러 앱 replica의 부팅마다 실행하지 않습니다.
[Railway pre-deploy](https://docs.railway.com/deployments/pre-deploy-command)는 환경변수와
private network를 사용할 수 있고, 실패하면 배포를 진행하지 않습니다.
추후 migration은 기존 버전과 호환되도록 설계하고 DB 백업 및 단일 실행 경로를 유지합니다.

### Health check의 의미

`/health`는 인증/Host 제한 없이 HTTP 200 JSON을 반환하므로
[Railway health check](https://docs.railway.com/deployments/healthchecks)로 사용할 수 있습니다.
현재 liveness 검사이므로 DB 연결/스키마 준비를 보장하지 않습니다.
Railway의 배포 health check는 배포 활성화 시 검사이며 지속적인 모니터링은 아닙니다.
도메인 기능을 추가할 때 DB 준비 상태를 검사하는 readiness 도입 여부를 결정합니다.
