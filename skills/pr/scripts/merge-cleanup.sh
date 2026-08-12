#!/usr/bin/env bash
# PR 을 머지하고 브랜치를 정리한다. Phase 6 에서 부른다.
#
#   skills/pr/scripts/merge-cleanup.sh <PR번호> [통합브랜치]
#
# 문서 안 코드 블록으로 두었다가 같은 실수를 네 번 냈다 — 블록마다 새 셸이라
# 앞에서 정한 변수가 없고, 문서라서 한 번도 안 돌려봤다. 스크립트로 빼면
# 변수는 한 곳에 있고 시험으로 돌려볼 수 있다.
set -uo pipefail

PR="${1:?PR 번호를 넘겨라}"
BASE="${2:-}"

# ── 값은 여기서 한 번만 정한다 ──────────────────────────────────
BR=$(git rev-parse --abbrev-ref HEAD)

# head 를 올린 원격. base 와 다를 수 있다(fork). **머지 전에** 잡아둔다 —
# `--delete-branch` 가 로컬 브랜치를 지우고 나면 못 구한다.
HEAD_REMOTE=$(git config "branch.$BR.pushRemote" \
  || git config remote.pushDefault \
  || git config "branch.$BR.remote" \
  || echo origin)

[ -n "$BASE" ] || BASE=$(git symbolic-ref -q --short refs/remotes/origin/HEAD | sed 's|^origin/||')
BASE_REMOTE=$(git config "branch.$BASE.remote" || echo origin)

# ── 멈춘 요청에 시한을 건다 ─────────────────────────────────────
# gh·git 둘 다 요청 타임아웃 옵션이 없고 macOS 에는 timeout(1) 이 없다.
bounded() {
    local secs="$1"; shift
    local pid n=0
    "$@" & pid=$!
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt "$secs" ]; do sleep 1; n=$((n+1)); done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
        return 124                       # 시한 초과
    fi
    wait "$pid"
}

pr_state() {
    local out; out=$(mktemp)
    bounded 30 gh pr view "$PR" --json state -q .state > "$out" 2>/dev/null
    cat "$out"; rm -f "$out"
}

# ── 머지 ────────────────────────────────────────────────────────
# merge queue 를 쓰는 저장소는 --delete-branch 를 거부한다. 먼저 그것으로
# 시도하고, 거부당하면 플래그 없이 넣은 뒤 큐가 끝나기를 기다린다.
QUEUED=0
if ! bounded 60 gh pr merge "$PR" --merge --delete-branch; then
    printf '  --delete-branch 가 거부됐다(merge queue로 보인다). 플래그 없이 넣는다\n' >&2
    bounded 60 gh pr merge "$PR" --merge || {
        printf '차단됨 — 큐에 넣지 못했다. 인증·권한·체크를 확인한다\n' >&2
        exit 1
    }
    QUEUED=1
fi

# ── 큐면 끝날 때까지 기다린다 ───────────────────────────────────
ST=MERGED
if [ "$QUEUED" = "1" ]; then
    # 시험이 20분을 기다릴 수는 없으므로 환경변수로 연다. 평소에는 안 건드린다.
    DEADLINE=$(( $(date +%s) + ${CLEANUP_WAIT_SEC:-1200} ))
    while :; do
        ST=$(pr_state)
        [ "$ST" = "MERGED" ] && break
        [ "$ST" = "CLOSED" ] && break
        [ "$(date +%s)" -ge "$DEADLINE" ] && break
        sleep "${CLEANUP_POLL_SEC:-20}"
    done
fi

if [ "$ST" != "MERGED" ]; then
    printf '머지가 안 끝났다(%s). 정리하지 않는다 — 큐와 체크를 확인한다\n' "$ST" >&2
    exit 1
fi

# ── 정리 ────────────────────────────────────────────────────────
# 지울 브랜치에서 먼저 나온다. 실패하면 멈춘다 — 그대로 가면 체크아웃된
# 브랜치를 지우려다 실패하고, 정리가 된 것처럼 보인다.
git switch "$BASE" || { printf '차단됨 — %s 로 옮기지 못했다. 워킹트리를 정리하고 다시 부른다\n' "$BASE" >&2; exit 1; }
bounded 60 git pull --ff-only || printf '  pull 을 못 했다(나중에)\n' >&2

# 원격 브랜치: 이미 없으면 성공, 조회 자체가 실패하면 로컬을 남긴다.
# --exit-code 는 「없음」에만 2를 준다. 다른 값은 인증·전송 문제다.
git ls-remote --exit-code --heads "$HEAD_REMOTE" "$BR" >/dev/null 2>&1
case $? in
    0)  bounded 60 git push "$HEAD_REMOTE" --delete "$BR" \
            || { printf '원격 삭제 실패 — 로컬도 남긴다\n' >&2; exit 1; } ;;
    2)  printf '  원격에 이미 없다(자동 삭제 설정으로 보인다)\n' >&2 ;;
    *)  printf '원격 조회 실패 — 지워졌는지 알 수 없어 로컬을 남긴다\n' >&2; exit 1 ;;
esac

git branch -D "$BR" 2>/dev/null || printf '  로컬 브랜치가 이미 없다\n' >&2

# 낡은 추적 ref 는 **브랜치를 올린 그 원격**에서 턴다. 인자 없이 부르면
# base 쪽만 훑어 fork 의 낡은 ref 가 남는다.
bounded 60 git fetch --prune "$HEAD_REMOTE" || printf '  prune 을 못 했다(나중에)\n' >&2
[ "$BASE_REMOTE" = "$HEAD_REMOTE" ] || bounded 60 git fetch --prune "$BASE_REMOTE" \
    || printf '  base 원격 prune 을 못 했다(나중에)\n' >&2

printf '정리 완료 — %s 머지됨, %s/%s 와 로컬 브랜치를 지웠다\n' "$PR" "$HEAD_REMOTE" "$BR"
