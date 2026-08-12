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
# **봇 둘이 각각 현재 head 를 봤는지** 확인한다.
#
# 증거는 세 채널로 온다 — 리뷰가 전부가 아니다.
#   리뷰      가장 좋다. commit_id 가 붙어 있어 SHA 로 바로 대조된다
#   코멘트    claude 워크플로가 --comment 로 돌면 여기로 온다. SHA 가 없다
#   반응(👍)  codex 가 지적할 것이 없으면 이것만 남긴다. SHA 가 없다
#
# 실제로 PR #33 은 codex 가 반응만, claude 가 코멘트만 남겼다 — 리뷰 목록만
# 보면 **그 PR 은 영원히 머지할 수 없다.**
#
# SHA 가 없는 채널은 **시각**으로 판정한다. head 커밋이 올라간 뒤에 남은
# 증거면 그 커밋을 보고 남긴 것이다.
# 봇 로그인은 **정확히** 대조한다. `contains("claude")` 로 보면
# `claude-review-helper` 같은 아무 계정이 리뷰 하나 남겨 통과시킬 수 있다.
BOTS="${REQUIRED_BOTS:-chatgpt-codex-connector[bot] claude[bot]}"

# SHA 있는 증거(리뷰·인라인 코멘트)만 자동으로 받는다.
seen_bot_sha() {                   # $1 = 정확한 로그인
    local bot="$1" f rc=1
    f=$(mktemp)
    bounded 30 gh api --paginate "repos/{owner}/{repo}/pulls/$PR/reviews" \
        -q ".[] | select(.user.login == \"$bot\") | .commit_id" > "$f" 2>/dev/null
    grep -qx "$PR_OID" "$f" && rc=0
    if [ "$rc" != 0 ]; then
        bounded 30 gh api --paginate "repos/{owner}/{repo}/pulls/$PR/comments" \
            -q ".[] | select(.user.login == \"$bot\") | .commit_id" > "$f" 2>/dev/null
        grep -qx "$PR_OID" "$f" && rc=0
    fi
    rm "$f" 2>/dev/null
    return "$rc"
}

# SHA 없는 증거(이슈 코멘트·👍 반응)가 있는지만 본다. **통과시키지는 않는다** —
# 그 시각이 head 가 올라간 시각보다 뒤인지 알 방법이 없다. 커밋 메타데이터의
# 날짜는 로컬에서 만든 시각이라 push 시각이 아니다.
# 반응은 `+1` 만 본다. codex 는 검토를 시작할 때 `eyes` 를 남기고, 그 뒤 리뷰가
# 실패할 수도 있다 — 그것을 완료로 읽으면 안 본 코드가 머지된다.
seen_bot_shaless() {
    local bot="$1" f rc=1
    f=$(mktemp)
    bounded 30 gh api --paginate "repos/{owner}/{repo}/issues/$PR/comments" \
        -q ".[] | select(.user.login == \"$bot\") | .id" > "$f" 2>/dev/null
    [ -s "$f" ] && rc=0
    if [ "$rc" != 0 ]; then
        bounded 30 gh api --paginate "repos/{owner}/{repo}/issues/$PR/reactions" \
            -q ".[] | select(.user.login == \"$bot\" and .content == \"+1\") | .id" \
            > "$f" 2>/dev/null
        [ -s "$f" ] && rc=0
    fi
    rm "$f" 2>/dev/null
    return "$rc"
}

MISSING= ; SHALESS=
for bot in $BOTS; do
    seen_bot_sha "$bot" && continue
    if seen_bot_shaless "$bot"; then SHALESS="$SHALESS $bot"; else MISSING="$MISSING $bot"; fi
done
[ -z "$MISSING" ] || die "봇이 현재 head(${PR_OID:0:8})를 본 증거가 없다:$MISSING
       리뷰 뒤에 push 됐거나 아직 안 돌았다 — 그 커밋은 아무도 안 봤다.
       새 브랜치로 다시 올린다(규칙 7)"

if [ -n "$SHALESS" ] && [ -z "${CLEANUP_ALLOW_SHALESS:-}" ]; then
    die "봇 증거가 SHA 없는 채널로만 왔다:$SHALESS
       codex 는 지적이 없으면 👍 만, claude 는 --comment 로 돌면 코멘트만 남긴다.
       그것이 **현재 head** 를 본 것인지 기계가 확인할 수 없다.
       눈으로 확인한 뒤 다시 부른다:  CLEANUP_ALLOW_SHALESS=1 <이 스크립트> $PR"
fi
REVIEWED="$PR_OID"

# head 를 올린 원격. base 와 다를 수 있다(fork). 머지 **전에** 잡아둔다 —
# `--delete-branch` 가 로컬 브랜치를 지우고 나면 못 구한다.
HEAD_REMOTE=$(git config "branch.$BR.pushRemote" \
  || git config remote.pushDefault \
  || git config "branch.$BR.remote" \
  || echo origin)
HEAD_URL=$(git remote get-url --push "$HEAD_REMOTE" 2>/dev/null) \
    || die "원격 '$HEAD_REMOTE' 의 push URL 을 못 구했다"

# URL 을 `owner/repo` 로 **정규화해서 정확히** 비교한다. 부분문자열로 보면
# `me/work` 가 `me/work-backup` 에, `bob/h` 가 `alicebob/h` 에 들어맞아
# **엉뚱한 원격에서 브랜치를 지운다.**
url_nwo() {
    printf '%s' "$1" \
      | sed -E 's#^[a-z+]+://##; s#^[^@]*@##; s#^[^:/]*[:/]##; s#\.git$##; s#/$##' \
      | awk -F/ 'NF>=2 {print tolower($(NF-1) "/" $NF)}'
}
MY_NWO=$(url_nwo "$HEAD_URL")
PR_NWO=$(printf '%s/%s' "$PR_OWNER" "$PR_REPO" | tr '[:upper:]' '[:lower:]')
[ "$MY_NWO" = "$PR_NWO" ] \
    || die "PR #$PR 의 head 는 $PR_NWO 인데 내 push 대상은 ${MY_NWO:-?}($HEAD_URL) 다
       — 다른 저장소의 동명 브랜치다"
# base 원격도 **PR 이 향한 저장소**에서 정한다. 로컬 설정만 보면 fork 의 낡은
# origin/main 을 당겨 방금 머지한 변경이 빠진 base 에서 다음 작업이 시작된다.
# `gh pr view` 에는 baseRepository 필드가 없다(2.96 확인). API 로 직접 읽는다.
# 다른 gh 호출과 마찬가지로 실패를 확인한다. 여기만 안 보면 조회 실패가
# 「base 저장소를 모른다」로 보여 아래에서 로컬 설정으로 떨어진다
# (claude, PR #55).
BASE_NWO=$(bounded 30 gh api "repos/{owner}/{repo}/pulls/$PR" \
    -q '.base.repo.full_name' 2>/dev/null) \
    || die "PR #$PR 의 base 저장소를 못 읽었다(네트워크·인증). 정리하지 않는다"
# 부분문자열로 찾으면 `me/work` 가 `me/work-backup` 원격에 들어맞아 **엉뚱한
# 저장소에서 통합 브랜치를 당긴다.** head 쪽과 같은 정규화로 정확히 비교한다.
BASE_REMOTE=
if [ -n "$BASE_NWO" ]; then
    want=$(printf '%s' "$BASE_NWO" | tr '[:upper:]' '[:lower:]')
    for rmt in $(git remote); do
        [ "$(url_nwo "$(git remote get-url "$rmt" 2>/dev/null)")" = "$want" ] \
            && { BASE_REMOTE="$rmt"; break; }
    done
fi
if [ -z "$BASE_REMOTE" ]; then
    if [ -n "$BASE_NWO" ]; then
        # API 가 base 저장소를 알려줬는데 로컬에 그 원격이 없다. 폴백하면
        # **fork 의 낡은 base** 를 당겨 방금 머지한 변경이 빠진 채로 다음 작업이
        # 시작된다. 멈추고 원격을 붙이라고 한다.
        die "PR 의 base 저장소 $BASE_NWO 를 가리키는 원격이 없다.
       추가한 뒤 다시 부른다:  git remote add upstream https://github.com/$BASE_NWO.git"
    fi
    BASE_REMOTE=$(git config "branch.$BASE.remote" || echo origin)
fi

# ── 머지 ────────────────────────────────────────────────────────
# 저장소가 허용하는 전략을 쓴다. merge commit 을 끈 저장소에서 `--merge` 만
# 두 번 시도하면 **Phase 6 이 통째로 막힌다.** 기본은 --merge 다(규칙 2 —
# 커밋 단위를 남긴다). 없으면 squash·rebase 로 떨어진다. 그때는 이력이 접히므로
# 진행 기록이 해시가 아니라 제목을 가리켜야 한다(build 스킬).
# 허용 전략은 **저장소** 설정이다 — `gh pr view` 에는 없는 필드다.
# 한 번에 셋을 읽는다(claude, PR #55).
STRAT=--merge
ALLOW=$(mktemp)
bounded 30 gh repo view --json mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed \
    -q '"\(.mergeCommitAllowed) \(.squashMergeAllowed) \(.rebaseMergeAllowed)"' \
    > "$ALLOW" 2>/dev/null
read -r M_OK S_OK R_OK < "$ALLOW" || { M_OK=true; S_OK=true; R_OK=true; }
rm "$ALLOW" 2>/dev/null
if [ "$M_OK" = "false" ]; then
    if   [ "$S_OK" = "true" ]; then STRAT=--squash
    elif [ "$R_OK" = "true" ]; then STRAT=--rebase
    else die "이 저장소는 merge·squash·rebase 를 다 껐다. 설정을 확인한다"
    fi
    printf '  merge commit 이 꺼져 있다 — %s 로 머지한다\n' "$STRAT" >&2
fi

# --match-head-commit 이 리뷰된 커밋과 다르면 거부한다.
# merge queue 를 쓰는 저장소는 --delete-branch 를 거부하므로 두 갈래로 시도한다.
if ! bounded 60 gh pr merge "$PR" "$STRAT" --delete-branch --match-head-commit "$REVIEWED"; then
    printf '  --delete-branch 가 거부됐다(merge queue로 보인다). 플래그 없이 넣는다\n' >&2
    bounded 60 gh pr merge "$PR" "$STRAT" --match-head-commit "$REVIEWED" \
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
RLS=$(mktemp)
bounded 30 git ls-remote --exit-code --heads "$HEAD_REMOTE" "$BR" > "$RLS" 2>/dev/null
case $? in
    0)  # 원격이 아직 그 커밋을 가리키는지 본다. 큐를 기다리는 20분 사이에
        # 누가 push 하거나 브랜치를 다시 만들었으면 **그 새 커밋이 날아간다** —
        # 이 PR 에 없던 것이다. 리뷰된 SHA 에 묶어 지운다.
        REMOTE_OID=$(awk '{print $1; exit}' "$RLS")
        if [ "$REMOTE_OID" = "$REVIEWED" ]; then
            bounded 60 git push "$HEAD_REMOTE" --delete "$BR" \
                || { rm "$RLS" 2>/dev/null; die "원격 삭제 실패 — 로컬도 남긴다"; }
        else
            rm "$RLS" 2>/dev/null
            die "원격 $BR 이 ${REMOTE_OID:0:8} 를 가리킨다(리뷰된 것은 ${REVIEWED:0:8}).
       머지 뒤에 누가 push 했다 — 그 커밋을 지우지 않는다. 눈으로 확인한다"
        fi ;;
    2)  printf '  원격에 이미 없다(자동 삭제 설정으로 보인다)\n' >&2 ;;
    *)  rm "$RLS" 2>/dev/null; die "원격 조회 실패 — 지워졌는지 알 수 없어 로컬을 남긴다" ;;
esac
rm "$RLS" 2>/dev/null

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
