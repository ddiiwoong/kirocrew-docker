# KiroCrew + Tailscale (Docker, macOS/Linux)

> 🇺🇸 **English: [README.md](README.md)**

KiroCrew 게이트웨이를 **헤드리스 Docker 컨테이너**로 띄우고, Tailscale 사이드카를
통해 같은 tailnet 안의 다른 사람이 MagicDNS 이름으로 대시보드에 접속하게 하는 구성.

- 각 인스턴스 = `kirocrew-home` 볼륨 하나 = 독립된 설정·세션·자격증명. 호스트의
  다른 파일에 닿지 않는다. 이게 "별도 인스턴스"로 다른 사람에게 자기 KiroCrew 를
  주는 방법이다 — 테넌트당 인스턴스 하나.

실측 환경: macOS(arm64) + Rancher Desktop(dockerd/moby 백엔드).

---

## 0. 전제조건

| 항목 | 요구 |
| --- | --- |
| 컨테이너 엔진 | Rancher Desktop 또는 Docker Desktop, **`dockerd(moby)` 백엔드** (containerd 아님 — seccomp/compose 전제) |
| `docker` + `docker compose` | PATH 에 있어야 함. Rancher 는 `~/.rd/bin` 에 shim 을 둔다(스크립트가 자동 탐지) |
| Tailscale 계정 | tailnet 1개. 접속할 사람이 **같은 tailnet** 에 있어야 한다 |
| 포트 | 기본 `15476` (로컬 `127.0.0.1`) |

Rancher 백엔드 확인: **Preferences → Container Engine → dockerd(moby)**.

---

## 1. 파일 구성

| 파일 | 역할 |
| --- | --- |
| `docker-compose.yml` | 두 컨테이너: `tailscale`(netns 소유자, 포트 발행) + `kirocrew`(게이트웨이, netns 공유) |
| `kirocrew.sh` | 헬퍼: preflight → up → **netns 자동 보정** → 검증. 서브커맨드 `tsauth` / `login` / `check` / `down` |
| `.env.example` | 설정 템플릿 — `.env` 로 복사해 채운다 |
| `kirocrew-seccomp.json` | seccomp 프로필(arm64 포함). kirocrew 컨테이너 내부 샌드박스용 |
| `.gitignore` | `.env`·`*.pem`·`*.crt`·로컬 상태 제외 |

> `.env` 에는 Tailscale auth key, tailnet 이름, 노드 IP 가 들어간다 — gitignore
> 돼 있으며 절대 커밋하면 안 된다.

---

## 2. 빠른 시작

```bash
cp .env.example .env            # 포트는 HOST_PORT/KIROCREW_PORT 두 줄만 고친다

./kirocrew.sh                   # preflight → up → netns 보정 → 검증

./kirocrew.sh tsauth            # TS_AUTHKEY 가 없으면: 출력된 URL 을 열어 "Connect" 승인

# 승인 후 tailnet 이름/IP 확인:
docker compose exec tailscale tailscale status --json \
  | grep -E '"DNSName"|"TailscaleIPs"' | head -3
#   -> Self DNSName = kirocrew.<tailnet>.ts.net.  /  TailscaleIPs = 100.x.y.z

# 그 이름/IP 로 CORS 채우기(3절) → docker compose up -d

./kirocrew.sh login             # 게이트웨이를 Kiro 모델에 연결

./kirocrew.sh check             # 상태만 점검
./kirocrew.sh down              # 내리기 (볼륨 보존)
```

로컬 전용이면 tailnet 단계를 건너뛰고 `http://127.0.0.1:15476` 로 바로 쓴다.

---

## 3. tailnet 이름으로 접속하기 — `KIROCREW_CORS_ORIGINS` (필수)

게이트웨이는 자기가 서비스하지 않는 `Host` 헤더를 **403 "Host header not allowed"**
로 거절한다(DNS-rebinding 방어). 기본 허용은
`localhost / 127.0.0.1 / ::1 / kirocrew.localhost` 뿐이라, tailnet FQDN 을 추가해야 한다.

**표기 세 개를 모두** 넣는다 — 허용 목록은 호스트명 완전일치이고, Tailscale 이
클라이언트에 따라 FQDN·짧은이름·노드IP 중 어느 것으로도 Host 를 건넨다:

```bash
# <FQDN> 와 <IP> 를 2절(status --json)에서 확인한 값으로 교체
LINE='KIROCREW_CORS_ORIGINS=http://kirocrew.tailXXXX.ts.net:15476,http://kirocrew:15476,http://100.x.y.z:15476'

if grep -q '^KIROCREW_CORS_ORIGINS=' .env; then
  sed -i.bak "s|^KIROCREW_CORS_ORIGINS=.*|$LINE|" .env && rm -f .env.bak
else
  printf '\n%s\n' "$LINE" >> .env
fi

docker compose up -d            # env 변경은 컨테이너 재생성이 필요
./kirocrew.sh                   # netns 보정 + 검증
```

**검증** (실제 tailnet 요청과 동일한 관문을 로컬에서 실측):

```bash
for H in kirocrew.tailXXXX.ts.net:15476 kirocrew:15476 100.x.y.z:15476; do
  printf '%-40s -> ' "$H"
  curl -sS -o /dev/null -w '%{http_code}\n' -H "Host: $H" http://127.0.0.1:15476/
done
# 세 줄 다 200(또는 401) = OK. 403 = 그 표기가 아직 허용 목록에 없는 것.
```

접속: 같은 tailnet 의 다른 사람이 브라우저로 `http://kirocrew.tailXXXX.ts.net:15476`.
대시보드 토큰: `docker compose exec kirocrew kirocrew token`.

> **IP 는 노드를 다시 만들면 바뀐다.** state 볼륨이 보존되는 한 그대로지만,
> 바뀌면 CORS 의 세 번째 항목(100.x)만 고친다.
>
> **이름 충돌:** tailnet 에 같은 이름 노드가 이미 있으면 Tailscale 이 `-N`
> (예: `kirocrew-1`)을 붙인다. [admin 콘솔](https://login.tailscale.com/admin/machines)
> 에서 옛 노드를 지우고 rename 한 뒤, 새 이름으로 CORS 를 다시 짠다.

---

## 4. netns 공유 함정 (가장 자주 당함)

`kirocrew` 는 `network_mode: service:tailscale` 로 tailscale 컨테이너의 네트워크
네임스페이스를 공유한다. **tailscale 컨테이너가 나중에 재시작하면**(대화형 로그인
대기, 수동 restart 등) 새 netns 가 생기고, 먼저 떠 있던 kirocrew 는 **죽은 netns 를
붙들고 남는다.**

- 증상이 헷갈린다: loopback 은 살아 있어 healthcheck 는 계속 `healthy` 인데
  **라우팅 테이블이 비고 DNS 가 전멸** → 컨테이너 안의 모든 외부 통신이
  `Could not resolve host` / `dispatch failure` 로 실패.
- `kiro-cli login` 의 `dispatch failure` 는 CA 문제처럼 보이지만 **대개 이것**이다.

**해결:** `./kirocrew.sh` (인자 없이) 를 돌린다. 두 컨테이너의 `started_epoch` 를
비교해 "tailscale 이 kirocrew 보다 최신"을 감지하면 **kirocrew 만 재시작**해 netns 를
다시 붙인다. `./kirocrew.sh check` 가 라우팅 항목 수를 보여준다.

> 순서 팁: tailscale 을 **먼저 인증**(`tsauth`)해 재시작 루프를 멈춘 뒤 netns 보정
> (`./kirocrew.sh`)을 하면 두 번 보정하지 않아도 된다.

---

## 5. 로그인 세션 유지하기 (재시작·재배포에도 유지)

**결론부터: 이미 유지된다 — 로그인은 한 번만.** 두 로그인 모두 named 볼륨에
저장되므로 `restart`, `down`/`up`, **이미지 업그레이드** 전부 인증이 유지된다.
**볼륨을 지울 때만** 재인증이 필요하다.

| 무엇 | 컨테이너 내부 저장 위치 | 유지하는 볼륨 |
| --- | --- | --- |
| **kiro-cli** (Kiro 모델 인증) — IAM Identity Center / 디바이스 플로우 토큰 | `~/.aws/sso/cache/` + `$HOME` 아래 kiro-cli 상태, 그리고 `/home/kirocrew` **자체가** 마운트 | `kirocrew-home` |
| **Tailscale** (tailnet 노드 신원) | `/var/lib/tailscale` | `kirocrew-tailscale-state` |

compose 가 컨테이너 사용자의 **홈 전체**를 볼륨으로 마운트하므로
(`kirocrew-home:/home/kirocrew`), kiro-cli 가 `$HOME` 아래에 쓰는 것 — 토큰 캐시
포함 — 은 전부 자동으로 볼륨에 들어간다. 추가 배선이 필요 없다.

**유지가 깨지는 경우(와 대처):**

| 동작 | 로그인 유지? |
| --- | --- |
| `docker compose restart` / `./kirocrew.sh` | ✅ 유지 |
| `docker compose down` → `up -d` | ✅ 유지 (down 은 named 볼륨을 보존) |
| 이미지 업그레이드 (`pull` + `up -d`) | ✅ 유지 |
| `docker compose down -v` | ❌ **안 됨** — `-v` 는 볼륨을 삭제한다. 테넌트를 통째로 지울 작정이 아니면 `-v` 를 쓰지 말 것. (`./kirocrew.sh down` 은 그냥 `down` 이라 안전) |
| `docker volume rm kirocrew-home` | ❌ 안 됨 — 같은 효과 |

**직접 확인** (토큰이 컨테이너 로컬이 아니라 볼륨에 있는지 실측). 당신 셸에서:

```bash
cd ~/repos/kirocrew-docker

# 1) 컨테이너 사용자 + 홈, 그리고 kiro-cli 토큰 캐시
docker compose exec kirocrew sh -c 'id; echo HOME=$HOME; ls -la ~/.aws/sso/cache/ 2>/dev/null'

# 2) /home/kirocrew 가 named 볼륨인지(임시 레이어 아님) 확인
docker inspect kirocrew \
  --format '{{range .Mounts}}{{.Type}} {{.Name}} -> {{.Destination}}{{"\n"}}{{end}}'
#   -> 기대값: volume kirocrew-home -> /home/kirocrew

# 3) 진짜 테스트: 게이트웨이를 재시작해도 재로그인이 필요 없는지
docker compose restart kirocrew && ./kirocrew.sh check
#   ./kirocrew.sh login 을 다시 하지 않아도 대시보드가 응답해야 한다
```

> **토큰 만료는 볼륨 유지와 별개다.** IAM Identity Center 액세스 토큰은 수명이
> 짧고, kiro-cli 가 저장된 refresh 토큰(역시 볼륨에 있음)으로 자동 갱신한다. SSO
> 세션 자체가 만료되면(조직 정책, 수 주 유휴) 대시보드가 "세션 만료"를 띄우고
> `./kirocrew.sh login` 을 한 번 다시 하면 된다 — 이건 SSO 수명이지 볼륨 문제가
> 아니다.
>
> **대화형 로그인을 아예 0 으로 하려면,** `.env` 에 reusable Tailscale `TS_AUTHKEY`
> 를 넣어 tailscale 단계를 없앨 수 있다. 다만 kiro-cli 의 SSO 디바이스 플로우는
> 처음 한 번(그리고 SSO 세션이 완전히 만료될 때)은 사람이 필요하다 — 설계상
> 그렇고, 비대화형 IdC 디바이스 플로우 로그인은 없다.

---

## 6. `./kirocrew.sh` 서브커맨드

| 명령 | 동작 |
| --- | --- |
| `./kirocrew.sh` | preflight → `up -d` → netns 보정 → `check` (기본) |
| `./kirocrew.sh check` | 상태만: 컨테이너 / tailscale 인증 / netns 라우팅 / 외부연결 / 대시보드 |
| `./kirocrew.sh check <host>` | 위 + 지정 호스트까지 TLS 도달 점검 |
| `./kirocrew.sh tsauth` | tailscale 대화형 로그인 URL 출력 |
| `./kirocrew.sh login` | `kiro-cli login --use-device-flow` (Start URL / Region 입력) |
| `./kirocrew.sh logout` | `kiro-cli logout` — 저장된 SSO 토큰 삭제. 계정을 바꾸려면 이어서 `login` |
| `./kirocrew.sh down` | `docker compose down` (볼륨 보존) |

---

## 7. 멀티테넌트 — 한 호스트에 여러 사람

이 번들을 **테넌트당 복제**한다. 분리할 네 가지:

| 테넌트별로 다르게 | 어떻게 |
| --- | --- |
| compose 프로젝트 | 디렉터리 분리 또는 `docker compose -p <name>` |
| 볼륨 | `docker-compose.yml` 의 `kirocrew-home` / `kirocrew-tailscale-state` `name:` (`kirocrew-home-alice` 등) |
| 포트 | `.env` 의 `HOST_PORT`/`KIROCREW_PORT` (15476, 15477, …) |
| Tailscale 노드 | `.env` 의 `TS_HOSTNAME`, 그리고 각자 `tsauth`/`TS_AUTHKEY` |
| 로그인 | 컨테이너별 `./kirocrew.sh login` 1회 |

격리 경계는 볼륨 + 컨테이너 + seccomp. 각 테넌트는 자기 `kirocrew-home` 만 본다.

---

## 8. 외부 공개 + Google(Gmail) 로그인 — Funnel + OAuth2 Proxy

tailnet FQDN(3절)은 **이미 tailnet에 있는 사람**만 닿는다. tailnet **밖**의 사람을
공개 인터넷으로 들이려면 — 포트포워딩·공인IP 없이 — **Tailscale Funnel** 앞에
**OAuth2 Proxy**를 세워 허용한 Gmail 계정만 통과시킨다.

```
외부 사용자 → Funnel(443) → oauth2-proxy(:4180) → [Google 로그인 + 이메일 화이트리스트] → kirocrew(:PORT)
                            (세 컨테이너가 tailscale netns 공유, 같은 127.0.0.1)
```

세 가지가 이미 `docker-compose.yml`에 배선돼 있다:
- `oauth2-proxy` 서비스 (`127.0.0.1:4180` 리스닝, upstream = kirocrew)
- `tailscale-serve.json` — Funnel 443 → 4180 선언, 부팅마다 자동 적용
  (재부팅·재배포에도 수동 `tailscale funnel` 명령 없이 공개 유지)
- `.env`의 Google 클라이언트 + 쿠키 시크릿 + 공개 FQDN 키

### 셋업 (한 번만)

**1) Google OAuth 클라이언트 발급** — [Google Cloud Console → Credentials](https://console.cloud.google.com/apis/credentials):
- "OAuth 2.0 Client ID", Application type: **Web application**
- **Authorized redirect URI**(정확히): `https://<내-FQDN>/oauth2/callback`
  (예: `https://kirocrew.tailXXXX.ts.net/oauth2/callback`)

**2) `.env` 채우기:**
```bash
cd ~/repos/kirocrew-docker

OAUTH2_PUBLIC_FQDN=kirocrew.tailXXXX.ts.net   # .env 에
OAUTH2_GOOGLE_CLIENT_ID=...                   # .env 에
OAUTH2_GOOGLE_CLIENT_SECRET=...               # .env 에

# 쿠키 시크릿 — 정확히 16/24/32 바이트여야 한다.
# 함정: `openssl rand -base64 32` 는 44글자 → 44바이트로 읽혀 거부된다.
# 32글자 평문을 쓸 것:
echo "OAUTH2_COOKIE_SECRET=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)" >> .env
```

**3) CORS 를 공개 HTTPS origin 으로** (Funnel 은 443, 포트 없음):
```bash
sed -i.bak 's|^KIROCREW_CORS_ORIGINS=.*|KIROCREW_CORS_ORIGINS=https://kirocrew.tailXXXX.ts.net|' .env && rm -f .env.bak
```

**4) 허용 Gmail 목록:**
```bash
cp authenticated_emails.txt.example authenticated_emails.txt
#   편집: 허용할 Gmail 을 한 줄에 하나. 목록 밖 계정은 로그인해도 거부.
```

**5) 기동** (Funnel 은 `tailscale-serve.json` 에서 자동 기동):
```bash
docker compose up -d
./kirocrew.sh                                 # netns 보정
docker compose exec tailscale tailscale funnel status   # 443 → 127.0.0.1:4180 떠야 함
```

### 접속

외부 사용자가 **`https://<내-FQDN>`** (포트 없음, https) 접속 → oauth2-proxy
Sign-In → "Sign in with Google" → 허용 Gmail → KiroCrew 대시보드
(그다음 대시보드 토큰: `docker compose exec kirocrew kirocrew token`).

> `curl https://<FQDN>/` 가 본문 `<title>Sign In</title>` 과 함께 **403** 을 내는 건
> **정상**이다 — 쿠키 없는 요청에 대한 proxy 의 로그인 페이지. 브라우저는 실제
> Google 플로우로 간다. **502** 는 proxy 가 안 뜬 것(트러블슈팅 참조).

### 다른 사람 추가 (유일하게 반복할 작업)
```bash
echo "them@gmail.com" >> authenticated_emails.txt
docker compose up -d          # 목록 다시 읽기
```

### 외부 공개 끄기
```bash
# 이번 부팅의 Funnel 광고 중단:
docker compose exec tailscale tailscale funnel --https=443 off
# 영구적으로: docker-compose.yml 의 TS_SERVE_CONFIG + 마운트 두 줄을 주석 처리하고
# oauth2-proxy 서비스를 멈춘다.
```

> tailnet ACL 에서 Funnel 허용(`nodeAttrs` → `funnel`)과 HTTPS 인증서 켜짐(보통 기본)이
> 전제. `tailscale funnel status` 가 `No serve config` 면 아직 광고 전일 뿐 에러 아님.

---

## 9. 트러블슈팅

| 증상 | 원인 / 조치 |
| --- | --- |
| `docker 를 찾을 수 없습니다` | Rancher Desktop 꺼짐, 또는 `~/.rd/bin` 이 PATH 밖 |
| `라우팅 테이블이 비어 있습니다` | 죽은 netns → `./kirocrew.sh` 재부착 (4절) |
| `kiro-cli login: dispatch failure` | 죽은 netns (4절) — `./kirocrew.sh check` 로 라우팅/외부연결 확인 |
| tailnet FQDN 이 403 | CORS 미반영 → 3절. `up -d` 재생성 했는지 확인 |
| 공개 FQDN 이 **502** | oauth2-proxy 죽음 → `docker compose logs oauth2-proxy`. 흔한 원인: `cookie_secret ... 44 bytes`(32글자 시크릿 쓸 것, 8절), Google client id/secret 누락, `authenticated_emails.txt` 미생성 |
| 공개 FQDN 이 **403** + "Sign In" 페이지 | **정상** — proxy 로그인 페이지. 브라우저로 열 것 (8절) |
| Google `redirect_uri_mismatch` | Console redirect URI 가 정확히 `https://<FQDN>/oauth2/callback` 여야 함 |
| Google 로그인 후 `403 Forbidden` | 그 Gmail 이 `authenticated_emails.txt` 에 없음 |
| tailscale `Logged out` | `./kirocrew.sh tsauth` → URL 승인 |
| 노드 이름이 `kirocrew-1` | 동명 노드 존재 → 콘솔에서 정리 (3절) |
| `down` 후 다시 로그인해야 했다 | `down -v` 를 쓴 것 — `-v` 는 볼륨을 지운다 (5절). 그냥 `down` 을 쓸 것 |
| 대시보드 "세션 만료" | SSO 세션 완전 만료 → `./kirocrew.sh login` 1회 (5절) |

---

## 라이선스

MIT. `LICENSE` 참조.
