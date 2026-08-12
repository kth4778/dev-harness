#!/usr/bin/env bash
# inspect 1·2번의 기계 판정. Phase 5 에서 부른다.
#
#   "${CLAUDE_PLUGIN_ROOT}/skills/inspect/scripts/check-branch-commits.sh" [통합브랜치]
#
# 체크리스트에 코드 블록으로 두었더니 **블록마다 새 셸이라 BASE 가 없었다** —
# `..HEAD` 가 `HEAD..HEAD` 로 읽혀 커밋을 하나도 못 세고 조용히 통과했다.
# 같은 병을 pr 스킬에서 이미 겪어 스크립트로 뺐다(PR #49). 여기도 같이 한다.
set -uo pipefail

BASE_BRANCH="${1:-}"
FAIL=0
bad() { printf 'FAIL — %s\n' "$1" >&2; FAIL=1; }
ok()  { printf 'PASS — %s\n' "$1"; }

# detached HEAD 면 `--abbrev-ref` 가 문자열 "HEAD" 를 준다. 그것은 ASCII 이고
# 보호 브랜치 이름과도 달라서 **그대로 통과한다** — 밀어 올릴 브랜치가 없는데.
# inspect 는 커밋을 하나씩 체크아웃해 보므로 실제로 이 상태에 놓인다.
BR=$(git symbolic-ref -q --short HEAD) \
  || { printf 'FAIL — detached HEAD 다. 기능 브랜치로 돌아온다: git switch -\n' >&2; exit 1; }

# ── 1. 브랜치 전략 ──────────────────────────────────────────────
[ -n "$BASE_BRANCH" ] \
  || BASE_BRANCH=$(git symbolic-ref -q --short refs/remotes/origin/HEAD | sed 's|^origin/||')
[ -n "$BASE_BRANCH" ] || { bad "통합 브랜치를 못 정했다. 인자로 넘긴다"; exit 1; }

# 흔한 이름 셋만 박아두면 프로젝트가 정한 `release` 같은 이름을 놓친다.
# **인자로 받은 통합 브랜치 자체**도 거부 대상이다.
case "$BR" in
    main|master|develop) bad "보호 브랜치($BR)에서 작업하고 있다" ;;
esac
[ "$BR" = "$BASE_BRANCH" ] && bad "통합 브랜치($BR)에서 작업하고 있다"

# head 와 base 이름이 ASCII 인가. claude-code-action 이 base 의 비ASCII 를 거부한다.
printf '%s\n%s\n' "$BR" "$BASE_BRANCH" | LC_ALL=C grep -n '[^ -~]' \
    && bad "브랜치 이름에 비ASCII 가 있다 — base 면 claude 리뷰 잡이 죽는다" \
    || ok "브랜치 이름이 ASCII 다"

# push 대상 원격. **실패를 삼키지 않는다** — 못 구하면 아래 소유자 대조가
# 빈 값으로 돌아 「한 번도 안 쓴 브랜치」로 오판한다.
HEAD_REMOTE=$(git config "branch.$BR.pushRemote" \
  || git config remote.pushDefault \
  || git config "branch.$BR.remote" || echo origin)
HEAD_URL=$(git remote get-url --push "$HEAD_REMOTE" 2>/dev/null) \
  || { bad "원격 '$HEAD_REMOTE' 의 push URL 을 못 구했다. 재사용 검사를 못 한다"; exit 1; }
HEAD_OWNER=$(printf '%s' "$HEAD_URL" \
  | sed -E 's#^[a-z+]+://[^/]*/##; s#^[^/]*:##; s#/[^/]+$##; s#\.git$##; s#^.*/##')
[ -n "$HEAD_OWNER" ] || { bad "원격 URL 에서 소유자를 못 뽑았다: $HEAD_URL"; exit 1; }

# 이 브랜치로 PR 이 열렸던 적이 있나. fork 면 parent 를 짚는다.
# gh 에는 요청 타임아웃 옵션이 없다. 응답이 안 오면 Phase 5 가 통째로 멈추므로
# 직접 잰다 — merge-cleanup.sh 의 bounded 와 같은 이유다.
bounded() {
    local secs="$1"; shift
    local pid n=0
    "$@" & pid=$!
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt "$secs" ]; do sleep 1; n=$((n+1)); done
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null
        n=0; while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 5 ]; do sleep 1; n=$((n+1)); done
        kill -KILL "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        return 124
    fi
    wait "$pid"
}
gh_out() { local o; o=$(mktemp); bounded 30 "$@" > "$o" 2>/dev/null; cat "$o"; rm "$o" 2>/dev/null; }

UPSTREAM=$(gh_out gh repo view --json parent,nameWithOwner \
  -q '.parent.nameWithOwner // .nameWithOwner')
if [ -n "$UPSTREAM" ]; then
    # **지금 열려 있는 PR 하나는 뺀다.** Phase 6 에서 이 스크립트를 다시 부르면
    # 그 PR 이 목록에 있어 「재사용」으로 잡힌다 — 정상 흐름이 늘 FAIL 이 된다.
    # 그 하나를 빼도 안전하다: 열린 PR 이 둘 이상이거나 머지·닫힌 것이 있으면
    # 여전히 걸린다.
    CUR=$(gh_out gh pr list --repo "$UPSTREAM" --state open --head "$BR" --limit 10 \
      --json number -q '.[0].number // empty')
    PRIOR=$(gh_out gh pr list --repo "$UPSTREAM" --state all --head "$BR" --limit 1000 \
      --json number,state,headRepositoryOwner \
      -q "[.[] | select(((.headRepositoryOwner.login // \"\") | ascii_downcase)
             == (\"$HEAD_OWNER\" | ascii_downcase))
            | select(.number != ($CUR // -1))] | .[0] // empty" 2>/dev/null)
    if [ -n "$PRIOR" ]; then
        bad "이 브랜치로 이미 PR 이 열렸다: $PRIOR — 통합 브랜치에서 새로 판다"
    elif [ -n "$CUR" ]; then
        ok "이 브랜치의 PR 은 지금 열린 #$CUR 하나다"
    else
        ok "이 브랜치로 열린 PR 이 없다"
    fi
else
    printf '  (gh 로 저장소를 못 읽었다 — 재사용 검사를 건너뛴다)\n' >&2
fi

# ── 2. 커밋 단위 ────────────────────────────────────────────────
# BASE 는 **여기서** 구한다. upstream 이 있으면 그쪽을 먼저 본다 — fork 의
# origin/<base> 는 대개 낡아서, 그것으로 재면 남의 커밋이 내 것으로 세어진다.
BASE_REMOTE=$(git remote | grep -x upstream \
  || git config "branch.$BASE_BRANCH.remote" || echo origin)
# ref 가 **있어도** 가져온다. 낡은 것으로 merge-base 를 재면 그 사이 upstream 에
# 들어온 남의 커밋이 내 기능 커밋으로 세어진다 — 있으면 건너뛰던 것이 그 구멍이었다.
bounded 30 git fetch --no-tags "$BASE_REMOTE" "$BASE_BRANCH" 2>/dev/null
git rev-parse --verify -q "$BASE_REMOTE/$BASE_BRANCH" >/dev/null \
  || { bad "$BASE_REMOTE/$BASE_BRANCH 를 못 찾았다. fetch 하거나 통합 브랜치를 확인한다"; exit 1; }

BASE=$(git merge-base HEAD "$BASE_REMOTE/$BASE_BRANCH") \
  || { bad "merge-base 를 못 구했다"; exit 1; }

N=$(git log --oneline "$BASE"..HEAD | wc -l | tr -d ' ')
printf '커밋 %s개 (%s..HEAD)\n' "$N" "${BASE:0:8}"
git log --oneline "$BASE"..HEAD

# 구현만·테스트만 있는 커밋 — 갈라진 것이다(규칙 2). 리팩터·문서는 예외.
# 경로 요소·접미사로만 잡는다. 부분문자열로 보면 `ContestService.java` 가
# 테스트로, `Foo.java` 가 소스로 잡혀 갈라진 커밋이 통과한다.
TESTPAT='(^|/)(test|tests|spec|specs|__tests__)/|(^|/)[^/]*([._-](test|spec)|Test|Tests|Spec|IT)\.[A-Za-z]+$'

# 결과를 **파일로** 받는다. `while` 을 파이프 뒤에 두면 서브셸이라 거기서 세운
# 값이 밖으로 안 나온다 — 그래서 갈라진 커밋을 찍고도 exit 0 이었다.
SPLIT=$(mktemp)
while read -r sha subject; do
    case "$subject" in refactor:*|docs:*|chore:*) continue ;; esac
    files=$(git show --name-only --format= "$sha")
    has_test=$(printf '%s\n' "$files" | grep -cE "$TESTPAT" || true)
    has_src=$(printf '%s\n' "$files"  | grep -vE "$TESTPAT" | grep -c . || true)
    [ "$has_test" -gt 0 ] && [ "$has_src" -gt 0 ] && continue
    printf '  갈라진 커밋: %s %s\n' "${sha:0:8}" "$subject" >> "$SPLIT"
done <<SPLITEOF
$(git log --format='%H %s' "$BASE"..HEAD)
SPLITEOF
if [ -s "$SPLIT" ]; then
    cat "$SPLIT" >&2
    bad "구현만·테스트만 있는 커밋이 있다 — 하나로 합친다(규칙 2)"
fi
rm "$SPLIT" 2>/dev/null

# 같은 파일을 세 번 이상 건드린 커밋들 — 한 자리를 여러 번 고쳤다는 신호.
printf '\n같은 파일을 반복해 건드린 횟수:\n'
git log --format=%H "$BASE"..HEAD | while read -r c; do
    git show --name-only --format= "$c"
done | sort | uniq -c | sort -rn | awk '$1 >= 3 {print "  " $1 "회  " $2}'

printf '\n하위 기능 수를 세어 커밋 수(%s)와 비교한다. 많으면 접는다(규칙 2).\n' "$N"
exit "$FAIL"
