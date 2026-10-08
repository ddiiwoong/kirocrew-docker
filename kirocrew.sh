#!/usr/bin/env bash
# =============================================================================
#  KiroCrew + Tailscale compose 스택 헬퍼 (bash / macOS·Linux 트랙).
#  kirocrew.ps1 의 포팅본. 동작·함정 처리 동일.
#
#  이 스택의 함정: netns 공유. tailscale 이 나중에 재시작하면 kirocrew 는
#  죽은 네임스페이스를 붙들고 남는다. loopback 은 살아 있어 healthcheck 는
#  healthy 로 보이지만 라우팅 테이블이 비고 DNS 가 전멸한다.
#  -> StartedAt 비교로 kirocrew 만 재시작해 보정한다.
#
#  사용법:
#    ./kirocrew.sh                 # 준비 검사 + up + netns 보정 + 검증 (기본)
#    ./kirocrew.sh check           # 아무것도 바꾸지 않고 상태만 검증
#    ./kirocrew.sh check <host>    # 조직 고유 호스트까지 TLS 검증에 포함
#    ./kirocrew.sh tsauth          # tailscale 대화형 로그인 URL 보기
#    ./kirocrew.sh login           # kiro-cli 디바이스 플로우 로그인
#    ./kirocrew.sh logout          # kiro-cli 로그아웃 (다른 계정으로 바꿀 때)
#    ./kirocrew.sh down            # 내리기 (볼륨은 보존)
# =============================================================================
set -euo pipefail
cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"

KC='kirocrew'
TS='kirocrew-tailscale'

# ---- docker CLI 위치 (Rancher Desktop 은 ~/.rd/bin 에 shim 을 둔다) ----------
if command -v docker >/dev/null 2>&1; then
    DOCKER=docker
elif [ -x "$HOME/.rd/bin/docker" ]; then
    DOCKER="$HOME/.rd/bin/docker"
    export PATH="$HOME/.rd/bin:$PATH"   # compose 플러그인도 같이 집도록
else
    echo "   [FAIL] docker 를 찾을 수 없습니다. Rancher Desktop 이 켜져 있고" >&2
    echo "          ~/.rd/bin 이 PATH 에 있는지 확인하세요." >&2
    exit 1
fi
dc() { "$DOCKER" compose "$@"; }

# ---- 출력 헬퍼 ---------------------------------------------------------------
c_cyan=$'\033[36m'; c_green=$'\033[32m'; c_red=$'\033[31m'; c_gray=$'\033[90m'; c_yellow=$'\033[33m'; c_off=$'\033[0m'
step() { printf '\n%s== %s%s\n' "$c_cyan" "$1" "$c_off"; }
ok()   { printf '   %s[OK]%s   %s\n' "$c_green" "$c_off" "$1"; }
bad()  { printf '   %s[FAIL]%s %s\n' "$c_red" "$c_off" "$1"; }
note() { printf '   %s[..]%s   %s\n' "$c_gray" "$c_off" "$1"; }

# docker 의 StartedAt 은 RFC3339(나노초). epoch 로 바꿔 비교한다.
# GNU date(-d)와 BSD date(macOS, -j -f) 양쪽을 지원한다.
started_epoch() {
    local raw; raw="$("$DOCKER" inspect "$1" --format '{{.State.StartedAt}}' 2>/dev/null)" || return 1
    [ -n "$raw" ] || return 1
    local base="${raw%.*}"                 # 소수점(나노초) 제거: 2026-10-04T04:00:00
    base="${base%Z}"; base="${base//T/ }"  # Z 제거, T -> 공백
    if date -d "2000-01-01" +%s >/dev/null 2>&1; then
        date -u -d "$base" +%s 2>/dev/null  # GNU/Linux
    else
        date -u -j -f '%Y-%m-%d %H:%M:%S' "$base" +%s 2>/dev/null  # BSD/macOS
    fi
}

is_running() {
    [ "$("$DOCKER" inspect "$1" --format '{{.State.Running}}' 2>/dev/null)" = "true" ]
}

preflight() {
    step 'Preflight'
    local f
    for f in docker-compose.yml .env kirocrew-seccomp.json; do
        if [ -f "$f" ]; then ok "$f"; else bad "$f 없음"; echo "$f 가 이 디렉터리에 없습니다." >&2; exit 1; fi
    done
}

repair_netns() {
    is_running "$TS" && is_running "$KC" || return 0
    local ts kc; ts="$(started_epoch "$TS")" || return 0; kc="$(started_epoch "$KC")" || return 0
    [ -n "$ts" ] && [ -n "$kc" ] || return 0
    if [ "$ts" -gt "$kc" ]; then
        note "tailscale 이 kirocrew 보다 나중에 시작됨 -- netns 재부착"
        dc restart "$KC" >/dev/null
        sleep 3
        ok 'kirocrew 재시작 완료'
    else
        ok 'netns 정상 (kirocrew 가 tailscale 이후에 시작됨)'
    fi
}

do_up() {
    preflight
    step 'docker compose up -d'
    dc up -d
    sleep 4
    step 'netns 점검'
    repair_netns
}

do_check() {
    local extra_host="${1:-}"
    step '컨테이너 상태'
    dc ps || true

    if ! is_running "$KC"; then bad 'kirocrew 가 실행 중이 아닙니다'; return; fi

    step 'tailscale 인증 상태'
    local tsout; tsout="$("$DOCKER" exec "$TS" tailscale status --peers=false 2>&1 || true)"
    if   grep -qE 'Logged out|NeedsLogin' <<<"$tsout"; then note '미인증 -- ./kirocrew.sh tsauth'
    else
        ok "$(head -1 <<<"$tsout" | sed 's/^ *//')"
        local dns; dns="$("$DOCKER" exec "$TS" tailscale status --json 2>/dev/null | sed -n 's/.*"DNSName": *"\([^"]*\)".*/\1/p' | head -1 || true)"
        [ -n "$dns" ] && ok "MagicDNS: ${dns%.}"
    fi

    step 'netns 살아 있나 (라우팅 테이블)'
    local routes; routes="$("$DOCKER" exec "$KC" sh -c 'wc -l < /proc/net/route' 2>/dev/null | tr -d ' ' || echo 0)"
    if [ "${routes:-0}" -le 1 ]; then
        bad '라우팅 테이블이 비어 있습니다 -- 죽은 netns. ./kirocrew.sh (재부착) 또는 docker compose restart kirocrew'
        return
    fi
    ok "라우팅 항목 $((routes - 1))개"

    step '외부 연결 점검 (컨테이너 안에서)'
    local hosts=(controlplane.tailscale.com github.com oidc.ap-northeast-2.amazonaws.com)
    [ -n "$extra_host" ] && hosts=("$extra_host" "${hosts[@]}")
    local h code
    for h in "${hosts[@]}"; do
        if code="$("$DOCKER" exec "$KC" curl -sS -o /dev/null -w '%{http_code}' --max-time 12 "https://$h/" 2>&1)"; then
            printf '   %s[OK]%s   %-38s code=%s\n' "$c_green" "$c_off" "$h" "$code"
        else
            printf '   %s[FAIL]%s %-38s %s\n' "$c_red" "$c_off" "$h" "$code"
        fi
    done

    step '대시보드'
    # 포트는 .env 를 읽지 않고 docker 에서 가져온다(.env 에는 TS_AUTHKEY 가 있다).
    local port; port="$("$DOCKER" port "$TS" 2>/dev/null | sed -n 's/.*:\([0-9]\{1,\}\) *$/\1/p' | head -1 || true)"
    port="${port:-5476}"
    local sc; sc="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$port/" 2>/dev/null || echo 000)"
    if [ "$sc" = "200" ] || [ "$sc" = "401" ] || [ "$sc" = "403" ]; then
        ok "http://127.0.0.1:$port 도달 (HTTP $sc)"
    else
        bad "http://127.0.0.1:$port 도달 실패 (code=$sc)"
    fi
    note '대시보드 토큰 URL: docker compose exec kirocrew kirocrew token'
}

show_tsauth() {
    is_running "$TS" || { bad "$TS 가 실행 중이 아닙니다"; return; }
    step 'tailscale 로그인 URL 찾기 (최근 로그 200줄)'
    local log; log="$("$DOCKER" logs --tail 200 "$TS" 2>&1 || true)"
    local url; url="$(grep -oE 'https://login\.tailscale\.com/[^ ]+' <<<"$log" | head -1 || true)"
    if [ -n "$url" ]; then
        ok '아래 URL 을 브라우저로 열어 승인하세요:'
        printf '   %s%s%s\n' "$c_yellow" "$url" "$c_off"
    else
        note '로그인 URL 이 로그에 없습니다 (이미 인증됐거나 TS_AUTHKEY 사용 중).'
        "$DOCKER" exec "$TS" tailscale status --peers=false 2>&1 | head -3 || true
    fi
}

do_login() {
    is_running "$KC" || { bad "$KC 가 실행 중이 아닙니다"; return; }
    step 'kiro-cli 로그인 (디바이스 플로우)'
    note 'Start URL 과 Region 을 물어봅니다. dispatch failure 가 나면 ./kirocrew.sh check 로 netns/외부연결부터 확인하세요.'
    dc exec kirocrew kiro-cli login --use-device-flow --license pro
}

do_logout() {
    is_running "$KC" || { bad "$KC 가 실행 중이 아닙니다"; return; }
    step 'kiro-cli 로그아웃 (저장된 SSO 토큰 삭제)'
    dc exec kirocrew kiro-cli logout || note 'logout 이 실패했거나 이미 로그아웃 상태입니다.'
    ok '다른 계정으로 다시 로그인하려면: ./kirocrew.sh login'
    note 'Google(oauth2-proxy) 계정도 바꾸려면 브라우저에서 /oauth2/sign_out 을 여세요 (README 8절).'
}

case "${1:-up}" in
    up)     do_up; do_check "${2:-}" ;;
    check)  do_check "${2:-}" ;;
    tsauth) show_tsauth ;;
    login)  do_login ;;
    logout) do_logout ;;
    down)   step 'docker compose down'; dc down ;;
    *)      echo "사용법: $0 [up|check|tsauth|login|logout|down] [extra-host]" >&2; exit 2 ;;
esac
