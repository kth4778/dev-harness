#!/usr/bin/env bash
# PR 을 머지하고 브랜치를 정리한다. Phase 6 에서 부른다.
#
#   "${CLAUDE_PLUGIN_ROOT}/skills/pr/scripts/merge-cleanup.sh" <PR번호>
#
# 문서 안 코드 블록으로 두었다가 같은 실수를 네 번 냈다 — 블록마다 새 셸이라
# 앞에서 정한 변수가 없었고, 문서라서 한 번도 안 돌려봤다. 스크립트로 빼면
# 변수는 한 곳에 있고 hooks/tests/cleanup.sh 가 갈래를 실제로 잰다.
set -uo pipefail

PR="${1:?PR 번호를 넘겨라}"

# ── 멈춘 요청에 시한을 건다 ─────────────────────────────────────
# gh·git 둘 다 요청 타임아웃 옵션이 없고 macOS 에는 timeout(1) 이 없다.
bounded() {
    local secs="$1"; shift
    local pid n=0
    "$@" & pid=$!
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt "$secs" ]; do sleep 1; n=$((n+1)); done
    if kill -0 "$pid" 2>/dev/null; then
        # TERM 을 무시하는 프로세스가 있다. 유예를 준 뒤 KILL 로 올린다 —
        # 안 그러면 뒤의 wait 가 시한 없이 붙잡혀 이 함수가 무의미해진다.
        kill -TERM "$pid" 2>/dev/null
        n=0; while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 5 ]; do sleep 1; n=$((n+1)); done
        kill -KILL "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        return 124                       # 시한 초과
    fi
    wait "$pid"
}

# 조회는 실패를 **삼키지 않는다.** cat 의 성공이 bounded 의 실패를 덮으면
# 호출부가 「아직 안 끝났다」로 오해하고 시한까지 헛돈다.
gh_json() {
    local out rc; out=$(mktemp)
    bounded 30 gh pr view "$PR" --json "$1" -q "$2" > "$out" 2>/dev/null; rc=$?
    cat "$out"; rm -f "$out"
    return "$rc"
}

die() { printf '차단됨 — %s\n' "$1" >&2; exit 1; }

# ── PR 이 정말 이 브랜치의 것인지 먼저 확인한다 ─────────────────
# `gh pr merge <N>` 은 번호로 지정한 PR 을 머지하는데, 정리는 체크아웃된
# 브랜치를 지운다. 번호를 잘못 넣거나 체크아웃을 빠뜨리면 **아무 상관 없는
# 브랜치를 원격까지 지운다.** 지우기 전에 반드시 대조한다.
BR=$(git rev-parse --abbrev-ref HEAD)
PR_HEAD=$(gh_json headRefName .headRefName) || die "PR #$PR 을 못 읽었다"
[ "$PR_HEAD" = "$BR" ] || die "PR #$PR 의 head 는 '$PR_HEAD' 인데 지금은 '$BR' 에 있다"

# base 도 PR 에서 가져온다. origin/HEAD 를 믿으면 develop 을 쓰는 저장소에서
# 엉뚱한 브랜치로 옮겨 놓고 정리했다고 보고한다.
BASE=$(gh_json baseRefName .baseRefName) || die "PR #$PR 의 base 를 못 읽었다"

# PR 의 현재 head 와 **로컬 HEAD 가 같은지** 본다. 이름만 같고 실체가 다른
# 경우가 있다 — 다른 fork 의 동명 브랜치, 또는 아직 push 안 한 커밋.
# 그대로 가면 `git branch -D` 가 **push 안 된 커밋을 날린다.**
PR_OID=$(gh_json headRefOid .headRefOid) || die "PR #$PR 의 head 커밋을 못 읽었다"
LOCAL_OID=$(git rev-parse HEAD)

# head **저장소**도 대조한다. 다른 fork 의 동명 브랜치가 같은 커밋을 가리키면
# 이름도 SHA 도 같아서 통과하고, **내 fork 에서 브랜치를 지운다.**
PR_OWNER=$(gh_json headRepositoryOwner .headRepositoryOwner.login) \
    || die "PR #$PR 의 head 저장소 소유자를 못 읽었다"
PR_REPO=$(gh_json headRepository .headRepository.name) \
    || die "PR #$PR 의 head 저장소 이름을 못 읽었다"
[ "$PR_OID" = "$LOCAL_OID" ] \
    || die "PR #$PR 의 head 는 ${PR_OID:0:8} 인데 로컬 HEAD 는 ${LOCAL_OID:0:8} 다.
       push 안 한 커밋이 있거나 다른 저장소의 동명 브랜치다"

# **리뷰가 실제로 붙은 커밋**을 얻는다. 현재 head 를 그대로 쓰면
# `--match-head-commit` 이 무의미하다 — 리뷰 뒤에 push 됐다면 그 새 커밋이
# 이미 head 이기 때문이다. 이 워크플로에는 synchronize 가 없어 **그 커밋은
# 리뷰를 못 받는다.**
# **봇 둘이 각각 현재 head 를 리뷰했는지** 본다. 마지막 리뷰의 커밋만 보면
# 봇이 옛 SHA 를 리뷰하고 누가 push 한 뒤 다른 사람이 새 head 를 리뷰했을 때
# 통과한다 — 그 코드는 봇이 안 봤다.
REVIEWS=$(mktemp)
bounded 30 gh api "repos/{owner}/{repo}/pulls/$PR/reviews" \
    -q '.[] | "\(.user.login) \(.commit_id)"' > "$REVIEWS" 2>/dev/null \
    || { rm "$REVIEWS" 2>/dev/null; die "리뷰 목록을 못 읽었다"; }
MISSING=
for bot in ${REQUIRED_BOTS:-codex claude}; do
    grep -i "$bot" "$REVIEWS" | awk '{print $2}' | grep -qx "$PR_OID" \
        || MISSING="$MISSING $bot"
done
rm "$REVIEWS" 2>/dev/null
[ -z "$MISSING" ] || die "봇 리뷰가 현재 head(${PR_OID:0:8})에 없다:$MISSING
       리뷰 뒤에 push 됐거나 아직 안 돌았다 — 그 커밋은 아무도 안 봤다.
       새 브랜치로 다시 올린다(규칙 7)"
REVIEWED="$PR_OID"

# head 를 올린 원격. base 와 다를 수 있다(fork). 머지 **전에** 잡아둔다 —
# `--delete-branch` 가 로컬 브랜치를 지우고 나면 못 구한다.
HEAD_REMOTE=$(git config "branch.$BR.pushRemote" \
  || git config remote.pushDefault \
  || git config "branch.$BR.remote" \
  || echo origin)
HEAD_URL=$(git remote get-url --push "$HEAD_REMOTE" 2>/dev/null) \
    || die "원격 '$HEAD_REMOTE' 의 push URL 을 못 구했다"
printf '%s' "$HEAD_URL" | grep -qi "$PR_OWNER/$PR_REPO" \
    || die "PR #$PR 의 head 는 $PR_OWNER/$PR_REPO 인데
       내 push 대상은 $HEAD_URL 이다 — 다른 저장소의 동명 브랜치다"
# base 원격도 **PR 이 향한 저장소**에서 정한다. 로컬 설정만 보면 fork 의 낡은
# origin/main 을 당겨 방금 머지한 변경이 빠진 base 에서 다음 작업이 시작된다.
# `gh pr view` 에는 baseRepository 필드가 없다(2.96 확인). API 로 직접 읽는다.
BASE_NWO=$(bounded 30 gh api "repos/{owner}/{repo}/pulls/$PR" \
    -q '.base.repo.full_name' 2>/dev/null)
BASE_REMOTE=
[ -n "$BASE_NWO" ] && BASE_REMOTE=$(git remote -v | awk -v n="$BASE_NWO" \
    'index($0, n) && /\(fetch\)/ {print $1; exit}')
[ -n "$BASE_REMOTE" ] || BASE_REMOTE=$(git config "branch.$BASE.remote" || echo origin)

# ── 머지 ────────────────────────────────────────────────────────
# --match-head-commit 이 리뷰된 커밋과 다르면 거부한다.
# merge queue 를 쓰는 저장소는 --delete-branch 를 거부하므로 두 갈래로 시도한다.
if ! bounded 60 gh pr merge "$PR" --merge --delete-branch --match-head-commit "$REVIEWED"; then
    printf '  --delete-branch 가 거부됐다(merge queue로 보인다). 플래그 없이 넣는다\n' >&2
    bounded 60 gh pr merge "$PR" --merge --match-head-commit "$REVIEWED" \
        || die "머지 요청이 실패했다. 인증·권한·체크, 그리고 리뷰 뒤 push 가 있었는지 확인한다"
fi

# ── 머지가 **실제로** 끝났는지 본다 ─────────────────────────────
# 명령이 성공해도 큐에 넣기만 했거나 auto-merge 를 켜 둔 것일 수 있다.
# 어느 갈래로 왔든 상태를 직접 확인한다 — 안 그러면 열린 PR 의 브랜치를 지운다.
DEADLINE=$(( $(date +%s) + ${CLEANUP_WAIT_SEC:-1200} ))
ST=
while :; do
    ST=$(gh_json state .state) || die "PR 상태를 못 읽었다. 정리하지 않는다"
    [ "$ST" = "MERGED" ] && break
    [ "$ST" = "CLOSED" ] && break
    [ "$(date +%s)" -ge "$DEADLINE" ] && break
    sleep "${CLEANUP_POLL_SEC:-20}"
done
[ "$ST" = "MERGED" ] || die "머지가 안 끝났다($ST). 큐와 체크를 확인한다"

# ── 정리 ────────────────────────────────────────────────────────
# 지울 브랜치에서 먼저 나온다. 실패하면 멈춘다 — 그대로 가면 체크아웃된
# 브랜치를 지우려다 실패하고, 정리가 된 것처럼 보인다.
git switch "$BASE" || die "$BASE 로 옮기지 못했다. 워킹트리를 정리하고 다시 부른다"
# 원격을 명시한다. 인자 없이 부르면 브랜치에 설정된 upstream 을 따라가
# **PR 이 향한 저장소가 아닌 곳**에서 당긴다 — 방금 머지한 변경이 빠진다.
bounded 60 git pull --ff-only "$BASE_REMOTE" "$BASE" \
    || printf '  pull 을 못 했다(나중에)\n' >&2

# 원격 브랜치: 이미 없으면 성공, 조회 자체가 실패하면 로컬을 남긴다.
# --exit-code 는 「없음」에만 2를 준다. 다른 값은 인증·전송 문제다.
bounded 30 git ls-remote --exit-code --heads "$HEAD_REMOTE" "$BR"
case $? in
    0)  bounded 60 git push "$HEAD_REMOTE" --delete "$BR" \
            || die "원격 삭제 실패 — 로컬도 남긴다" ;;
    2)  printf '  원격에 이미 없다(자동 삭제 설정으로 보인다)\n' >&2 ;;
    *)  die "원격 조회 실패 — 지워졌는지 알 수 없어 로컬을 남긴다" ;;
esac

if ! git branch -D "$BR" 2>/dev/null; then
    # 정말 없는 것과 지우지 못한 것을 가른다. ref 가 남아 있으면 실패다 —
    # 그대로 「정리 완료」를 찍으면 그 브랜치가 재사용 대상으로 남는다.
    git show-ref --verify -q "refs/heads/$BR" \
        && die "로컬 브랜치를 못 지웠다(ref 잠김·다른 worktree 에서 체크아웃)" \
        || printf '  로컬 브랜치가 이미 없다\n' >&2
fi

# 낡은 추적 ref 는 **브랜치를 올린 그 원격**에서 턴다. 인자 없이 부르면
# base 쪽만 훑어 fork 의 낡은 ref 가 남는다.
bounded 60 git fetch --prune "$HEAD_REMOTE" || printf '  prune 을 못 했다(나중에)\n' >&2
[ "$BASE_REMOTE" = "$HEAD_REMOTE" ] || bounded 60 git fetch --prune "$BASE_REMOTE" \
    || printf '  base 원격 prune 을 못 했다(나중에)\n' >&2

printf '정리 완료 — #%s 머지됨(%s), %s/%s 와 로컬 브랜치를 지웠다\n' \
    "$PR" "${REVIEWED:0:8}" "$HEAD_REMOTE" "$BR"
