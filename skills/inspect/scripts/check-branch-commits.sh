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
# 진단에 URL 을 실을 때는 **자격 증명을 가린다.** `https://user:token@host/...`
# 가 그대로 stderr 에 실리면 훅·시험·CI 로그에 토큰이 남는다 (codex, PR #66).
# merge-cleanup 에는 앞 라운드에 넣고 여기를 빠뜨렸다.
redact() {
    printf '%s' "$1" | sed -E 's#(://)[^@/]*@#\1***@#'
}
# 호스트를 뽑는다. **프로토콜의 기본 포트는 뗀다** — `ssh://…:22/` 를 명시하는
# 구성이 있는데 PR URL 쪽에는 포트가 없어, 같은 서버를 다른 서버로 판정한다
# (codex, PR #66). 기본이 아닌 포트는 남긴다 — 사내 미러가 포트로만 갈리는
# 경우를 여전히 가려야 한다. merge-cleanup 의 url_host 와 같은 규칙이다.
host_of() {
    local u="$1" h scheme
    case "$u" in
        *://*)  scheme=$(printf '%s' "$u" | sed -E 's#://.*$##' | tr '[:upper:]' '[:lower:]')
                h=$(printf '%s' "$u" | sed -E 's#^[a-z+]+://##; s#^[^@]*@##; s#/.*$##') ;;
        *)      scheme=ssh
                h=$(printf '%s' "$u" | sed -E 's#^[^@]*@##; s#[:/].*$##') ;;
    esac
    h=$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')
    case "$scheme:$h" in
        ssh:*:22)    h=${h%:22} ;;
        https:*:443) h=${h%:443} ;;
        http:*:80)   h=${h%:80} ;;
        git:*:9418)  h=${h%:9418} ;;
    esac
    printf '%s' "$h"
}
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
    # **push URL 이 여럿일 수 있다.** 첫 것만 보면 두 번째 fork 에서 같은
    # 브랜치로 열었던 PR 이력이 걸리지 않는데, `git push <이름>` 은 그쪽에도
    # 올라간다 — PR 없이 커밋만 쌓이는 바로 그 재사용이다 (codex, PR #67).
    # merge-cleanup 은 앞 라운드에 `--all` 로 고쳤고 여기를 빠뜨렸다.
    HEAD_URLS=$(git remote get-url --push --all "$HEAD_REMOTE" 2>/dev/null) \
      || { bad "원격 '$HEAD_REMOTE' 의 push URL 을 못 구했다. 재사용 검사를 못 한다"; exit 1; }
    HEAD_URL=$(printf '%s\n' "$HEAD_URLS" | awk 'NR==1{print}')
    # 소유자를 전부 모은다. 하나라도 옛 PR 이 걸리면 FAIL 이다.
    HEAD_OWNERS=
    while IFS= read -r hu; do
        [ -n "$hu" ] || continue
        o=$(printf '%s' "$hu" \
          | sed -E 's#^[a-z+]+://[^/]*/##; s#^[^/]*:##; s#/+$##; s#\.git$##; s#/[^/]+$##; s#^.*/##')
        [ -n "$o" ] \
          || { bad "원격 URL 에서 소유자를 못 뽑았다: $(redact "$hu")"; exit 1; }
        case "$HEAD_OWNERS" in
            *"|$o|"*) : ;;
            *) HEAD_OWNERS="${HEAD_OWNERS:-|}$o|" ;;
        esac
    done <<HUEOF
$HEAD_URLS
HUEOF
    HEAD_OWNER=$(printf '%s' "$HEAD_URL" \
      | sed -E 's#^[a-z+]+://[^/]*/##; s#^[^/]*:##; s#/+$##; s#\.git$##; s#/[^/]+$##; s#^.*/##')
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
    # **프로세스 그룹으로 띄운다.** 부모 PID 만 죽이면 git 이 띄운 ssh·전송
    # helper 가 남아, 시한이 지난 뒤에도 원격을 계속 바꾼다 — 스크립트의 실패
    # 보고와 실제 상태가 갈린다 (codex, PR #69).
    # `set -m` 을 켜면 자식이 자기 그룹의 리더가 되어 `kill -그룹` 이 닿는다.
    set -m
    "$@" & pid=$!
    set +m
    # 1 초 간격이면 즉시 끝나는 명령도 매번 1 초를 버린다. 시험이 이 스크립트를
    # 40 번 넘게 돌리고 한 번에 bounded 를 여러 차례 부르므로 그것이 쌓인다
    # (codex, PR #62 — merge-cleanup 은 앞 라운드에 같은 이유로 고쳤다).
    local limit=$(( secs * 20 ))
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt "$limit" ]; do sleep 0.05; n=$((n+1)); done
    if kill -0 "$pid" 2>/dev/null; then
        # 그룹 전체에 보낸다(음수 PID). 그룹이 없으면 프로세스 하나로 떨어진다.
        kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
        n=0; while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.05; n=$((n+1)); done
        kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
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
UPSTREAM_URL=
IS_FORK=
if [ -n "$HEAD_OWNER" ]; then
    # 실패를 삼키면 UPSTREAM 이 비어 「건너뛴다」 갈래로 빠지고 **재사용 검사가
    # 조용히 꺼진다.** git fetch 인증은 되는데 gh 인증만 없는 경우가 실제로 있다.
    # **한 호출로 받는다.** 두 번 부르면 두 번째만 실패했을 때 URL 이 비고,
    # 그러면 아래 호스트 대조가 **조용히 꺼진다** — 이 검사가 막으려는 오판이
    # 조회 한 번의 실패로 다시 열린다 (codex, PR #64).
    # 실패를 삼키는 함정을 이 세션에서 또 밟았다.
    UP_RAW=$(gh_out gh repo view --json parent,nameWithOwner,url \
      -q '[(.parent.nameWithOwner // ""), .nameWithOwner, (.parent.url // .url)] | @tsv') \
      || { bad "gh 로 저장소를 못 읽었다(인증·네트워크). 재사용 검사를 통과로 두지 않는다"; exit 1; }
    IS_FORK=$(printf '%s' "$UP_RAW"  | awk -F'\t' 'NR==1{print $1}')
    UPSTREAM=$(printf '%s' "$UP_RAW" | awk -F'\t' 'NR==1{print ($1 != "" ? $1 : $2)}')
    UPSTREAM_URL=$(printf '%s' "$UP_RAW" | awk -F'\t' 'NR==1{print $3}')
fi
if [ -n "$HEAD_OWNER" ] && [ -n "$UPSTREAM" ]; then
    # 뺄 번호는 **Phase 6 에서 넘긴 그 PR 하나**다. 비어 있으면 -1 로 둔다 —
    # jq 안에서 빈 값을 그대로 펼치면 구문 오류가 나고, 그 실패를 삼키면
    # PRIOR 이 조용히 비어 **재사용 검사가 통째로 무력해진다**(claude, PR #53).
    SKIP_PR="${PHASE6_PR:--1}"
    case "$SKIP_PR" in ''|*[!0-9-]*) SKIP_PR=-1 ;; esac

    # **호스트를 붙인다.** `--repo` 는 `[HOST/]OWNER/REPO` 를 받는데 이름만 주면
    # api.github.com 으로 간다 — 사내 GitHub 에서는 조회가 실패해 **Phase 5 가
    # 항상 막히거나**, GitHub.com 의 동명 저장소 이력을 보고 오판한다
    # (codex, PR #66). merge-cleanup 은 앞 라운드에 고쳤고 여기를 빠뜨렸다.
    # **소유자 목록 전체**로 거른다. 앞 라운드에 HEAD_OWNERS 를 모아 놓고 판정은
    # 첫 소유자 하나로 했다 — 「고쳤다」고 보고했는데 동작이 그대로였다
    # (claude, PR #68). 모으는 것과 쓰는 것은 다른 일이다.
    UP_HOST=$(host_of "$UPSTREAM_URL")
    PRIOR=$(gh_out gh pr list --repo "${UP_HOST:+$UP_HOST/}$UPSTREAM" \
              --state all --head "$BR" --limit 1000 \
      --json number,state,headRepositoryOwner \
      -q "[.[] | select((\"|\" + ((.headRepositoryOwner.login // \"\") | ascii_downcase) + \"|\")
             | inside(\"$(printf '%s' "$HEAD_OWNERS" | tr '[:upper:]' '[:lower:]')\"))
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
# **이름만 보고 고르지 않는다.** `upstream` 이라는 원격이 다른 미러나 딴
# 프로젝트를 가리키는 경우가 있고, fork 의 upstream 설정이 낡아 있기도 하다.
# 그러면 엉뚱한 저장소를 fetch 해 관계없는 merge-base 로 커밋을 센다
# (codex, PR #62). 위에서 gh 로 확인한 $UPSTREAM 과 URL 을 대조한 뒤에 쓴다.
#
# url_nwo/url_host 는 merge-cleanup 과 같은 정규화다 — 끝 슬래시를 먼저 지운다.
nwo_of() {
    printf '%s' "$1" \
      | sed -E 's#^[a-z+]+://##; s#^[^@]*@##; s#^[^:/]*[:/]##; s#/+$##; s#\.git$##' \
      | awk -F/ 'NF>=2 {print tolower($(NF-1) "/" $NF)}'
}
# 호스트도 본다. NWO 만 맞추면 GitHub 원본과 사내 미러가 같아 보여, gh 가 확인한
# 저장소가 아닌 **미러의 base 를 fetch** 한다 — 관계없는 merge-base 로 커밋을
# 세거나 unrelated-history 로 Phase 5 가 막힌다 (codex, PR #63).
# merge-cleanup 에는 앞 라운드에 넣었고 여기를 빠뜨렸다. 같은 실수가 두 번째다.
BASE_REMOTE=
if [ -n "$UPSTREAM" ]; then
    want_up=$(printf '%s' "$UPSTREAM" | tr '[:upper:]' '[:lower:]')
    want_host=$(host_of "$UPSTREAM_URL")
    for rmt in $(git remote); do
        u=$(git remote get-url "$rmt" 2>/dev/null) || continue
        [ "$(nwo_of "$u")" = "$want_up" ] || continue
        # 한쪽 호스트가 비면(로컬 경로 원격) 대조할 것이 없다.
        [ -z "$want_host" ] || [ "$(host_of "$u")" = "$want_host" ] || continue
        BASE_REMOTE="$rmt"; break
    done
fi
# **확인한 upstream 이 있는데 그 원격이 없으면 폴백하지 않는다.** fork 의
# `origin/main` 은 대개 upstream 보다 뒤처져 있어, 그것으로 재면 **남의
# upstream 커밋까지 내 기능 커밋으로 세어진다** (codex, PR #65).
# merge-cleanup 은 같은 자리에서 멈추는데 여기만 폴백하고 있었다.
if [ -z "$BASE_REMOTE" ]; then
    # **fork 일 때만** 막는다. fork 가 아니면 UPSTREAM 은 이 저장소 자신이고
    # origin 이 곧 그것이므로, 원격 이름이 달라도 폴백이 맞는 답을 준다.
    if [ -n "$IS_FORK" ]; then
        bad "upstream $UPSTREAM 을 가리키는 원격이 없다.
       추가한 뒤 다시 돌린다:  git remote add upstream <그 저장소 URL>"
        exit 1
    fi
    BASE_REMOTE=$(git config "branch.$BASE_BRANCH.remote" || echo origin)
fi
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
# 구현 파일 안에 테스트를 둔 커밋 — **막지 않고 사람에게 넘긴다.**
COLOCATED=$(mktemp)
# 문서·설정만 바뀐 커밋
# `.txt` 는 빼 둔다 — 문서일 수도 데이터·소스일 수도 있어서 예외로 두면
# 실제 구현 커밋이 조용히 통과한다.
# `LICENSE|CHANGELOG|NOTICE` 뒤에 경계가 없어 `src/LICENSEManager.java` 같은
# 운영 소스가 문서로 분류됐다 — 그런 파일만 고친 커밋은 검사를 통째로
# 건너뛴다 (codex, PR #59). 토큰 뒤를 파일 끝이나 짧은 꼬리로 못박는다.
# `doc/` 를 경로 **어디서나** 받으면 `src/doc/parser.py` 만 넣은 구현 커밋이
# 문서로 분류돼 검사를 통째로 건너뛴다. `doc` 은 흔한 운영 패키지 이름이다
# (codex, PR #62). 저장소 최상위의 문서 디렉터리로 한정한다.
# 확장자 없는 `README`·`AUTHORS` 도 문서다. 안 넣으면 그것만 더한 커밋이
# 「구현만」으로 걸려 Phase 5 가 막힌다 (codex, PR #71 이 재현).
DOCPAT='\.(md|markdown|rst|adoc)$|^(docs|doc)/|(^|/)(LICENSE|CHANGELOG|NOTICE|README|AUTHORS|CONTRIBUTING)([._-][A-Za-z0-9]+)?$'
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
    # **제목으로 건너뛰지 않는다.** `chore: 런타임 설정 로더 변경` 처럼 운영
    # 코드만 고친 커밋이 제목 하나로 통과했다 — 이 검사의 핵심인 「구현만 있는
    # 커밋」 탐지가 Conventional Commit 접두사 하나로 무력해졌다 (codex, PR #67).
    #
    # 예외는 **바뀐 경로**로만 판정한다(아래 문서 예외). 순수 이동·이름 변경은
    # 테스트 파일도 함께 움직이므로 대개 그대로 통과한다. 남는 거짓 차단은
    # 사람이 그 자리에서 알아채지만, 거짓 통과는 이력에 남는다.

    # 두 벌로 나눈다.
    #  - files_all : 삭제 포함. 「이 커밋이 무엇을 건드렸나」를 분류할 때 쓴다
    #  - files     : 삭제 제외. 「테스트가 함께 있다」는 **증거**로 쓴다
    #
    # 한 벌로 두면 둘 중 하나가 깨진다. 삭제를 포함하면 유일한 테스트를 **지운**
    # 커밋이 「테스트가 있다」로 통과하고(PR #58), 삭제를 빼면 테스트만 지운
    # 커밋이 빈 목록이 되어 **검사를 통째로 건너뛴다**(PR #59). 둘 다 codex 다.
    # `-m --first-parent` — merge 커밋은 기본으로 **아무 경로도 안 낸다.** 그러면
    # 목록이 비어 아래 `continue` 로 빠지고, 테스트 없는 구현을 들여온 merge
    # 커밋이 그대로 통과한다 (codex, PR #68). 첫 부모와의 diff 를 낸다.
    # 일반 커밋에도 같은 결과다 — 실측으로 확인했다.
    files_all=$(git show --name-only --format= -m --first-parent "$sha")
    files=$(git show --name-only --format= -m --first-parent --diff-filter=d "$sha")
    [ -n "$files_all" ] || continue

    # 문서 예외는 **경로**로 본다. 제목만 보면 `docs(readme):` 나
    # `fix: 잘못된 설명을 고친다` 가 빠져 README 하나 고친 커밋이 FAIL 이 됐다.
    #
    # `grep -q` 를 쓰면 안 된다. 파일이 많아 파이프 버퍼가 차면 첫 비문서 경로에서
    # 닫히고 앞쪽이 SIGPIPE 로 죽어, pipefail 이 141 을 돌려준다 —
    # `|| continue` 가 그것을 「문서뿐」으로 읽어 **소스 커밋이 검사를 건너뛴다.**
    # 이 세션에서 같은 함정을 일곱 번째 밟았다. 스트림을 끝까지 읽는다.
    nondoc=$(printf '%s\n' "$files_all" | grep -vE "$DOCPAT" | grep -c . || true)
    [ "$nondoc" -gt 0 ] || continue

    # 살아 있는 테스트(삭제 아님)와 **삭제된** 테스트를 가른다.
    #
    # 기능을 제거하면서 구현과 테스트를 **함께 삭제**한 커밋은 규칙이 요구하는
    # 모양인데, 삭제를 빼고 세면 「테스트가 없다」로 걸렸다 (codex, PR #60).
    # 반대로 「구현은 고치고 테스트만 삭제」는 걸려야 한다. 둘을 구분한다.
    has_test=$(printf '%s\n' "$files" | grep -cE "$TESTPAT" || true)
    del_only=$(git show --name-only --format= -m --first-parent --diff-filter=D "$sha")
    del_test=$(printf '%s\n' "$del_only" | grep -cE "$TESTPAT" || true)
    # 경로가 테스트로 안 보여도, **지워진 파일 안에 인라인 테스트가 들어 있었으면**
    # 테스트를 함께 지운 것이다. `--diff-filter=d` 가 그 파일을 $files 에서 빼기
    # 때문에 아래 순회가 닿지 못한다 — 구현과 테스트를 한 파일에 두는 언어에서
    # 기능 파일째 걷어낸 정상 커밋이 「갈라진 커밋」으로 막혔다 (codex, PR #66).
    if [ "$del_test" = 0 ]; then
        while IFS= read -r df; do
            [ -n "$df" ] || continue
            n=$(git show "$sha^:$df" 2>/dev/null | grep -cE "$INLINE_TEST" || true)
            [ "${n:-0}" -gt 0 ] && { del_test=1; break; }
        done <<DELFILEEOF
$del_only
DELFILEEOF
    fi
    del_src=$(printf '%s\n' "$del_only" | grep -vE "$TESTPAT" \
                | grep -vE "$DOCPAT" | grep -c . || true)
    # 구현 수에서 **문서를 뺀다.** 안 빼면 테스트와 README 만 고친 커밋이
    # 「구현도 있다」로 읽혀 그대로 통과한다 (codex, PR #58).
    has_src=$(printf '%s\n' "$files_all" | grep -vE "$TESTPAT" \
                | grep -vE "$DOCPAT" | grep -c . || true)

    # 구현과 테스트를 **함께 지운** 것은 정상이다. 다만 그것으로 커밋 **전체**를
    # 면제하면 안 된다 — 같은 커밋에서 다른 운영 파일을 테스트 없이 고쳐도
    # 통과했다 (codex, PR #69 가 재현). 지운 짝만 양쪽 수에서 뺀다.
    if [ "$del_test" -gt 0 ] && [ "$del_src" -gt 0 ]; then
        has_src=$(( has_src - del_src ))
        [ "$has_src" -lt 0 ] && has_src=0
        # 남은 것이 없으면 이 커밋은 「함께 지운」 것이 전부다.
        #
        # **구현과 테스트 양쪽이 다 비었을 때만** 넘긴다. has_src 만 보면,
        # 짝을 지우면서 딴 테스트만 하나 더한 커밋이 통과했다 — 그건 갈라진
        # 테스트 커밋이다 (codex, PR #70 이 재현).
        [ "$has_src" -eq 0 ] && [ "$has_test" -eq 0 ] && continue
    fi
    [ "$has_test" -gt 0 ] && [ "$has_src" -gt 0 ] && continue

    # ── 구현 파일 안에 테스트를 같이 두는 관례(Rust·Go·JS) ──────────
    #
    # **판정하지 않는다. 사람에게 넘긴다.**
    #
    # 세 번 고쳤고 세 번 뚫렸다. 추가된 줄의 표식만 보면 기존 테스트를 고친
    # 커밋이 걸리고(PR #56), 파일이 테스트를 품었는지만 보면 구현만 고쳐도
    # 통과하고(PR #59), 첫 표식의 줄 번호를 경계로 삼으면 **그 뒤에 있는 운영
    # 코드까지 테스트로 세어진다**(PR #69 — codex 가 재현했다).
    #
    # 정확히 가르려면 블록의 중괄호를 세야 하는데 셸로 할 일이 아니다.
    # 대신 `test-coverage-notice` 훅과 같은 길을 간다 — **막지 않고 알린다.**
    # 조용히 통과하는 것과 목록에 찍히는 것은 다르다.
    if [ "$has_test" = 0 ] && [ "$has_src" -gt 0 ]; then
        inline=0
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            n=$(git show "$sha:$f" 2>/dev/null | grep -cE "$INLINE_TEST" || true)
            [ "${n:-0}" -gt 0 ] && { inline=1; break; }
            # 이 커밋에서 **지워진** 표식도 colocated 신호다 — 구현과 인라인
            # 테스트를 함께 걷어낸 커밋은 커밋 뒤 파일에 표식이 안 남는다.
            g=$(git show --format= -U0 "$sha" -- "$f" 2>/dev/null \
                  | grep '^-' | grep -cE "$INLINE_TEST" || true)
            [ "${g:-0}" -gt 0 ] && { inline=1; break; }
        done <<FILEEOF
$files
FILEEOF
        if [ "$inline" = 1 ]; then
            printf '  %s %s\n' "${sha:0:8}" "$subject" >> "$COLOCATED"
            continue
        fi
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

# **FAIL 이 아니다.** 기계가 가를 수 없는 자리라 사람에게 넘긴다.
# 조용히 통과하는 것과 목록에 찍히는 것은 다르다.
if [ -s "$COLOCATED" ]; then
    printf '  구현 파일 안에 테스트를 둔 커밋 — 눈으로 확인한다:\n' >&2
    cat "$COLOCATED" >&2
    printf '    (구현과 테스트가 같은 커밋에 들어 있는지 본다. 규칙 2)\n' >&2
fi
rm "$COLOCATED" 2>/dev/null

# 같은 파일을 세 번 이상 건드린 커밋들 — 한 자리를 여러 번 고쳤다는 신호.
printf '\n같은 파일을 반복해 건드린 횟수:\n'
git log --format=%H "$BASE"..HEAD | while read -r c; do
    git show --name-only --format= "$c"
done | sort | uniq -c | sort -rn | awk '$1 >= 3 {print "  " $1 "회  " $2}'

printf '\n하위 기능 수를 세어 커밋 수(%s)와 비교한다. 많으면 접는다(규칙 2).\n' "$N"
exit "$FAIL"
