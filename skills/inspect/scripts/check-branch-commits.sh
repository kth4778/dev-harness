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
# Phase 6 에서 다시 부를 때만 **그 PR 번호**를 넘긴다. 열린 PR 을 무조건 빼면
# Phase 5 에서 얼린 PR 에 커밋을 얹는 것을 못 잡는다 — 예외는 처리 중인 PR
# 하나로 못박는다.
PHASE6_PR=
[ "${2:-}" = "--phase6" ] && PHASE6_PR="${3:-}"
FAIL=0
bad() { printf 'FAIL — %s\n' "$1" >&2; FAIL=1; }
ok()  { printf 'PASS — %s\n' "$1"; }

# detached HEAD 면 `--abbrev-ref` 가 문자열 "HEAD" 를 준다. 그것은 ASCII 이고
# 보호 브랜치 이름과도 달라서 **그대로 통과한다** — 밀어 올릴 브랜치가 없는데.
# inspect 는 커밋을 하나씩 체크아웃해 보므로 실제로 이 상태에 놓인다.
# 원격이 있는지 본다. `git remote | grep -q` 로 쓰면 원격이 많을 때 파이프
# 버퍼가 차고 grep 이 먼저 닫혀 SIGPIPE + pipefail 로 **있는데 없다고 나온다.**
# 이 세션에서 같은 함정을 일곱 번 밟았다 — 파이프 뒤에는 -q 를 쓰지 않는다.
has_remote() { [ "$(git remote | grep -cx "$1" || true)" -gt 0 ]; }

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
# 원격이 없으면 재사용 검사를 **건너뛴다.** 판정 근거가 없는 것을 실패로 내면
# 로컬 전용 저장소에서 Phase 5 가 늘 막힌다 — 이 저장소의 「근거 없으면 막지
# 않는다」 원칙과 같다. 있는데 못 읽는 것은 다르다(그때는 실패).
HEAD_OWNER=
if has_remote "$HEAD_REMOTE"; then
    HEAD_URL=$(git remote get-url --push "$HEAD_REMOTE" 2>/dev/null) \
      || { bad "원격 '$HEAD_REMOTE' 의 push URL 을 못 구했다. 재사용 검사를 못 한다"; exit 1; }
    HEAD_OWNER=$(printf '%s' "$HEAD_URL" \
      | sed -E 's#^[a-z+]+://[^/]*/##; s#^[^/]*:##; s#/[^/]+$##; s#\.git$##; s#^.*/##')
    [ -n "$HEAD_OWNER" ] || { bad "원격 URL 에서 소유자를 못 뽑았다: $HEAD_URL"; exit 1; }
else
    printf '  (원격이 없다 — 재사용 검사를 건너뛴다)\n' >&2
fi

# 이 브랜치로 PR 이 열렸던 적이 있나. fork 면 parent 를 짚는다.
# **소유자를 못 구했으면 여기서 정말로 건너뛴다.** 위에서 「건너뛴다」고 찍고
# 그대로 내려와 빈 소유자로 대조하면, 아무 PR 도 안 걸려 검사가 조용히
# 무력해진다 (claude, PR #55).
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
# 마지막 명령(rm)의 상태가 아니라 **조회의 상태**를 돌려준다. 삼키면 조회 실패가
# 「결과 없음」으로 보여 검사가 조용히 꺼진다 — 이 세션에서 같은 실수를
# 다섯 번째 한다(grep -q SIGPIPE · cat · 서브셸 변수 · jq 오류 · 이것).
gh_out() {
    local o rc; o=$(mktemp)
    bounded 30 "$@" > "$o" 2>/dev/null; rc=$?
    cat "$o"; rm "$o" 2>/dev/null
    return "$rc"
}

UPSTREAM=
if [ -n "$HEAD_OWNER" ]; then
    # 실패를 삼키면 UPSTREAM 이 비어 「건너뛴다」 갈래로 빠지고 **재사용 검사가
    # 조용히 꺼진다.** git fetch 인증은 되는데 gh 인증만 없는 경우가 실제로 있다.
    UPSTREAM=$(gh_out gh repo view --json parent,nameWithOwner \
      -q '.parent.nameWithOwner // .nameWithOwner') \
      || { bad "gh 로 저장소를 못 읽었다(인증·네트워크). 재사용 검사를 통과로 두지 않는다"; exit 1; }
fi
if [ -n "$HEAD_OWNER" ] && [ -n "$UPSTREAM" ]; then
    # 뺄 번호는 **Phase 6 에서 넘긴 그 PR 하나**다. 비어 있으면 -1 로 둔다 —
    # jq 안에서 빈 값을 그대로 펼치면 구문 오류가 나고, 그 실패를 삼키면
    # PRIOR 이 조용히 비어 **재사용 검사가 통째로 무력해진다**(claude, PR #53).
    SKIP_PR="${PHASE6_PR:--1}"
    case "$SKIP_PR" in ''|*[!0-9-]*) SKIP_PR=-1 ;; esac

    PRIOR=$(gh_out gh pr list --repo "$UPSTREAM" --state all --head "$BR" --limit 1000 \
      --json number,state,headRepositoryOwner \
      -q "[.[] | select(((.headRepositoryOwner.login // \"\") | ascii_downcase)
             == (\"$HEAD_OWNER\" | ascii_downcase))
            | select(.number != $SKIP_PR)] | .[0] // empty") || {
        bad "PR 이력을 못 읽었다(네트워크·인증·시한). 재사용 검사를 통과로 두지 않는다"
        exit 1
    }
    if [ -n "$PRIOR" ]; then
        bad "이 브랜치로 이미 PR 이 열렸다: $PRIOR — 통합 브랜치에서 새로 판다"
    elif [ -n "$PHASE6_PR" ]; then
        ok "이 브랜치의 PR 은 지금 처리 중인 #$PHASE6_PR 하나다"
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
# 갱신 실패를 넘기면 **낡은 ref 로 판정한다** — 그 사이 들어온 남의 커밋이
# 내 기능 커밋으로 세어지고 접기 판정이 엉뚱해진다. 실패는 실패로 낸다.
if has_remote "$BASE_REMOTE"; then
    # refspec 을 **명시한다.** --single-branch 클론은 fetch refspec 이 좁아
    # `git fetch origin main` 이 FETCH_HEAD 에만 쓰고 origin/main 을 안 만든다 —
    # 그러면 바로 아래 검증이 늘 실패해 그 환경에서 Phase 5 가 통째로 막힌다.
    # --no-write-fetch-head 로 사용자의 FETCH_HEAD 를 건드리지 않는다.
    bounded 30 git fetch --no-tags --no-write-fetch-head "$BASE_REMOTE" \
        "+refs/heads/$BASE_BRANCH:refs/remotes/$BASE_REMOTE/$BASE_BRANCH" 2>/dev/null \
      || { bad "$BASE_REMOTE/$BASE_BRANCH 를 갱신하지 못했다(네트워크·인증). 낡은 ref 로 판정하지 않는다"; exit 1; }
    git rev-parse --verify -q "$BASE_REMOTE/$BASE_BRANCH" >/dev/null \
      || { bad "$BASE_REMOTE/$BASE_BRANCH 를 못 찾았다. fetch 하거나 통합 브랜치를 확인한다"; exit 1; }
    BASE_REF="$BASE_REMOTE/$BASE_BRANCH"
else
    # 원격이 없으면 로컬 통합 브랜치로 잰다.
    git rev-parse --verify -q "$BASE_BRANCH" >/dev/null \
      || { bad "통합 브랜치 '$BASE_BRANCH' 가 로컬에도 없다"; exit 1; }
    BASE_REF="$BASE_BRANCH"
fi

BASE=$(git merge-base HEAD "$BASE_REF") \
  || { bad "merge-base 를 못 구했다"; exit 1; }

N=$(git log --oneline "$BASE"..HEAD | wc -l | tr -d ' ')
printf '커밋 %s개 (%s..HEAD)\n' "$N" "${BASE:0:8}"
git log --oneline "$BASE"..HEAD

# 구현만·테스트만 있는 커밋 — 갈라진 것이다(규칙 2). 리팩터·문서는 예외.
# 경로 요소·접미사로만 잡는다. 부분문자열로 보면 `ContestService.java` 가
# 테스트로, `Foo.java` 가 소스로 잡혀 갈라진 커밋이 통과한다.
# 접미사·폴더뿐 아니라 **접두사**(pytest 의 `test_foo.py`, `spec_foo.rb`)도 본다.
TESTPAT='(^|/)(test|tests|spec|specs|__tests__)/|(^|/)(test|spec)[._-][^/]*$|(^|/)[^/]*([._-](test|spec)|Test|Tests|Spec|IT)\.[A-Za-z]+$'

# 결과를 **파일로** 받는다. `while` 을 파이프 뒤에 두면 서브셸이라 거기서 세운
# 값이 밖으로 안 나온다 — 그래서 갈라진 커밋을 찍고도 exit 0 이었다.
SPLIT=$(mktemp)
# 문서·설정만 바뀐 커밋
# `.txt` 는 빼 둔다 — 문서일 수도 데이터·소스일 수도 있어서 예외로 두면
# 실제 구현 커밋이 조용히 통과한다.
DOCPAT='\.(md|markdown|rst|adoc)$|(^|/)(docs|doc)/|(^|/)(LICENSE|CHANGELOG|NOTICE)'
# 파일 안에 테스트가 함께 있는 관례 — Rust `#[cfg(test)]`, Go `func Test`,
# Java `@Test`, pytest `def test_`, JS `describe(`/`it(`.
# `it\(` 에 경계가 없으면 `exit(`·`commit(`·`submit(` 에 걸려 **구현만 있는
# 커밋이 통과한다** (claude, PR #55). 줄 시작이나 비단어 뒤로 못박는다.
INLINE_TEST='#\[cfg\(test\)\]|func Test[A-Z]|@Test|def test_|(^|[^A-Za-z0-9_.])(describe|it|test)\('

while read -r sha subject; do
    # 커밋이 0개면 heredoc 에 개행 하나가 남아 이 루프가 **한 번 돈다.**
    # 그대로 두면 빈 SHA 가 「갈라진 커밋」으로 기록돼 거짓 FAIL 이 났다
    # (claude, PR #53).
    [ -n "$sha" ] || continue
    case "$subject" in refactor:*|refactor\(*|chore:*|chore\(*) continue ;; esac

    files=$(git show --name-only --format= "$sha")
    [ -n "$files" ] || continue

    # 문서 예외는 **경로**로 본다. 제목만 보면 `docs(readme):` 나
    # `fix: 잘못된 설명을 고친다` 가 빠져 README 하나 고친 커밋이 FAIL 이 됐다.
    #
    # `grep -q` 를 쓰면 안 된다. 파일이 많아 파이프 버퍼가 차면 첫 비문서 경로에서
    # 닫히고 앞쪽이 SIGPIPE 로 죽어, pipefail 이 141 을 돌려준다 —
    # `|| continue` 가 그것을 「문서뿐」으로 읽어 **소스 커밋이 검사를 건너뛴다.**
    # 이 세션에서 같은 함정을 일곱 번째 밟았다. 스트림을 끝까지 읽는다.
    nondoc=$(printf '%s\n' "$files" | grep -vE "$DOCPAT" | grep -c . || true)
    [ "$nondoc" -gt 0 ] || continue

    has_test=$(printf '%s\n' "$files" | grep -cE "$TESTPAT" || true)
    has_src=$(printf '%s\n' "$files"  | grep -vE "$TESTPAT" | grep -c . || true)
    [ "$has_test" -gt 0 ] && [ "$has_src" -gt 0 ] && continue

    # 경로로 못 가리는 관례가 있다 — 구현 파일 안에 테스트를 같이 두는 언어.
    # 추가된 줄에 테스트 표식이 있으면 함께 있는 것으로 본다.
    # `grep -q` 를 쓰면 안 된다. 매치하자마자 닫혀 앞의 grep 이 SIGPIPE 로 죽고
    # `set -o pipefail` 이 그것을 파이프라인 실패로 읽어 **이 예외가 통째로
    # 안 걸린다.** 이 세션에서 같은 실수를 여섯 번째 한다.
    #
    # 표식이 **새로 추가된 줄**에만 있으면 기존 테스트의 단언을 고친 커밋이 걸린다.
    # 그래서 바뀐 파일이 이미 테스트를 품고 있는지도 본다.
    # (`grep -q` 를 쓰지 않는다 — 위와 같은 이유다.)
    if [ "$has_test" = 0 ]; then
        added_test=$(git show --format= -U0 "$sha" | grep '^+' \
                       | grep -cE "$INLINE_TEST" || true)
        holds_test=0
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            n=$(git show "$sha:$f" 2>/dev/null | grep -cE "$INLINE_TEST" || true)
            [ "${n:-0}" -gt 0 ] && { holds_test=1; break; }
        done <<FILEEOF
$files
FILEEOF
        if [ "$added_test" -gt 0 ] || [ "$holds_test" = 1 ]; then continue; fi
    fi

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
