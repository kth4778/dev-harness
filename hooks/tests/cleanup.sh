#!/usr/bin/env bash
# skills/pr/scripts/merge-cleanup.sh 의 갈래를 잰다.
#
# gh 를 가짜로 갈아끼워 네트워크 없이 돌린다 — 진짜 PR 을 건드리지 않는다.
ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
SCRIPT="$ROOT/skills/pr/scripts/merge-cleanup.sh"
if [ ! -f "$SCRIPT" ]; then
    echo "  [SKIP] $SCRIPT 가 없다 — 훅만 담긴 옛 트리로 보인다"
    exit 0
fi
R=$(mktemp -d); BIN=$(mktemp -d)
trap 'rm -rf "$R" "$BIN"' EXIT

pass=0; fail=0
r() { if [ "$1" = "$2" ]; then pass=$((pass+1)); printf '  [OK ] '; else fail=$((fail+1)); printf '  [FAIL] '; fi
     printf '기대 %s / 실제 %s  %s\n' "$1" "$2" "$3"; }

# 가짜 gh. 환경변수로 행동을 바꾼다.
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
# 봇 증거 채널을 흉내 낸다. 스크립트는 리뷰 → 리뷰코멘트 → 이슈코멘트·반응
# 순으로 찾으므로, 어느 채널에 무엇을 놓는지가 갈래를 만든다.
#   GH_CH_CODEX / GH_CH_CLAUDE : review | comment | reaction | none
#   GH_REVIEWED / GH_REVIEWED_CLAUDE : 그 봇이 본 커밋(기본 현재 head)
# 스크립트는 이제 **정확한 로그인**으로 거른다.
ch()  { case "$1" in *codex*) printf '%s' "${GH_CH_CODEX:-review}" ;;
                     *claude*) printf '%s' "${GH_CH_CLAUDE:-review}" ;; esac; }
oid() { case "$1" in *codex*) printf '%s' "${GH_REVIEWED:-$GH_OID}" ;;
                     *claude*) printf '%s' "${GH_REVIEWED_CLAUDE:-${GH_REVIEWED:-$GH_OID}}" ;; esac; }
case "$1" in
  api)
    case "$*" in
      */commits/*)  printf '%s\n' "${GH_HEAD_TIME:-2020-01-01T00:00:00Z}"; exit 0 ;;
      */pulls/*/reviews*)
        for b in codex claude; do
          printf '%s' "$*" | grep -q "$b" || continue
          [ "$(ch $b)" = review ] && printf '%s\n' "$(oid $b)"
        done; exit 0 ;;
      */pulls/*/comments*)
        for b in codex claude; do
          printf '%s' "$*" | grep -q "$b" || continue
          [ "$(ch $b)" = comment ] && printf '%s\n' "$(oid $b)"
        done; exit 0 ;;
      */issues/*/comments*)
        for b in codex claude; do
          printf '%s' "$*" | grep -q "$b" || continue
          [ "$(ch $b)" = icomment ] && printf '%s\n' "1"
        done; exit 0 ;;
      */issues/*/reactions*)
        # 스크립트가 content == "+1" 을 요구한다. eyes 만 있으면 안 나온다.
        for b in codex claude; do
          printf '%s' "$*" | grep -q "$b" || continue
          case "$(ch $b)" in
            reaction)      printf '%s' "$*" | grep -q '"+1"' && printf '1\n' ;;
            reaction_eyes) : ;;
          esac
        done; exit 0 ;;
      *) printf '%s\n' "${GH_BASE_NWO:-}" ; exit 0 ;;   # base repo full_name
    esac ;;
esac
# 허용 전략은 저장소 설정이다 — repo view 로 온다.
case "$*" in
  *"repo view"*)
    printf '%s %s %s\n' "${GH_MERGE_OK:-true}" "${GH_SQUASH_OK:-true}" "${GH_REBASE_OK:-true}"
    exit 0 ;;
esac
case "$2" in
  view)
    case "$*" in
      *headRefName*)          printf '%s\n' "${GH_HEAD:-feature/x}" ;;
      *baseRefName*)          printf '%s\n' "${GH_BASE:-main}" ;;
      *headRefOid*)           printf '%s\n' "${GH_OID}" ;;
      *headRepositoryOwner*)  printf '%s\n' "${GH_OWNER:-me}" ;;
      *headRepository*)       printf '%s\n' "${GH_REPO:-work}" ;;
      *state*)                printf '%s\n' "${GH_STATE:-MERGED}" ;;
    esac
    exit "${GH_VIEW_RC:-0}" ;;
  merge)
    [ "${GH_DELETE_REJECT:-0}" = "1" ] && printf '%s\n' "$*" | grep -q -- --delete-branch && exit 1
    exit "${GH_MERGE_RC:-0}" ;;
esac
GH
chmod +x "$BIN/gh"; export PATH="$BIN:$PATH"

fresh() {
    rm -rf "$R"; mkdir -p "$R/remote" "$R/work"
    # 원격 경로가 `me/work` 를 담아야 head 저장소 대조를 통과한다.
    mkdir -p "$R/me"; git init -q --bare -b main "$R/me/work"
    ln -sfn "$R/me/work" "$R/remote"
    git clone -q "$R/me/work" "$R/work" 2>/dev/null
    cd "$R/work" || exit 1
    git config user.email t@t.t; git config user.name t
    printf 'base\n' > base.txt; git add base.txt; git commit -qm init
    git push -q origin main 2>/dev/null; git remote set-head origin main 2>/dev/null
    git switch -qc feature/x
    printf 'x\n' > f.txt; git add f.txt; git commit -qm work
    git push -q -u origin feature/x 2>/dev/null
}
# PR head SHA 는 로컬 HEAD 와 같아야 통과한다. 시험이 그 값을 맞춰 준다.
run() { CLEANUP_WAIT_SEC=2 CLEANUP_POLL_SEC=1 GH_OID="${GH_OID:-$(git rev-parse HEAD)}" \
    bash "$SCRIPT" 1 2>&1; }

echo "── 정상 경로 ──"
fresh; out=$(run); rc=$?
r 0 "$rc" '머지되고 정리까지 끝난다'
r "main" "$(git rev-parse --abbrev-ref HEAD)" '통합 브랜치로 옮겨져 있다'
r "" "$(git branch --list feature/x)" '로컬 브랜치가 지워졌다'
r "" "$(git ls-remote --heads origin feature/x)" '원격 브랜치가 지워졌다'

echo "── 파괴적 오작동을 막는다 ──"
fresh; out=$(GH_HEAD=feature/other run); rc=$?
r 1 "$rc" 'PR head 가 현재 브랜치와 다르면 멈춘다'
r "feature/x" "$(git branch --show-current)" '엉뚱한 브랜치를 안 지운다'
printf '%s' "$out" | grep -q "head 는" && r y y '무엇이 어긋났는지 알린다' || r y n '무엇이 어긋났는지 알린다'

echo "── base 를 PR 에서 가져온다 ──"
fresh; git branch -q develop; git push -q origin develop 2>/dev/null
out=$(GH_BASE=develop run); rc=$?
r 0 "$rc" 'base 가 develop 이어도 돈다'
r "develop" "$(git rev-parse --abbrev-ref HEAD)" 'origin/HEAD(main) 가 아니라 PR 의 base 로 옮긴다'

echo "── 머지가 실제로 끝났는지 본다 ──"
fresh; out=$(GH_STATE=OPEN run); rc=$?
r 1 "$rc" '명령이 성공해도 상태가 OPEN 이면 멈춘다'
r "feature/x" "$(git branch --show-current)" '열린 PR 의 브랜치를 안 지운다'
fresh; out=$(GH_STATE=CLOSED run); rc=$?
r 1 "$rc" '닫혔으면 정리하지 않는다'

echo "── 조회 실패를 삼키지 않는다 ──"
fresh; out=$(GH_VIEW_RC=1 run); rc=$?
r 1 "$rc" 'gh 조회가 실패하면 즉시 멈춘다'
r "feature/x" "$(git branch --show-current)" '아무것도 안 지운다'

echo "── 머지 요청 실패 ──"
fresh; out=$(GH_MERGE_RC=1 run); rc=$?
r 1 "$rc" '머지 요청이 실패하면 멈춘다'
printf '%s' "$out" | grep -q "리뷰 뒤 push" && r y y '리뷰 후 push 가능성을 알린다' || r y n '리뷰 후 push 가능성을 알린다'

echo "── merge queue 우회 ──"
fresh; out=$(GH_DELETE_REJECT=1 run); rc=$?
r 0 "$rc" '--delete-branch 가 거부돼도 플래그 없이 넣고 정리한다'
r "" "$(git branch --list feature/x)" '정리가 끝났다'

echo "── 원격에 이미 없을 때 ──"
fresh; git push -q origin --delete feature/x 2>/dev/null
out=$(run); rc=$?
r 0 "$rc" '이미 없으면 성공으로 친다'
r "" "$(git branch --list feature/x)" '로컬은 그래도 지운다'

echo "── 로컬 HEAD 와 PR head 를 대조한다 ──"
fresh; out=$(GH_OID=deadbeefdeadbeefdeadbeef run); rc=$?
r 1 "$rc" 'SHA 가 다르면 멈춘다(push 안 한 커밋·동명 브랜치)'
r "feature/x" "$(git branch --show-current)" 'push 안 한 커밋을 날리지 않는다'

echo "── 리뷰가 붙은 커밋에 고정한다 ──"
fresh; out=$(GH_REVIEWED=0123456789abcdef0123 run); rc=$?
r 1 "$rc" '리뷰가 다른 커밋에 붙어 있으면 멈춘다(리뷰 뒤 push)'
printf '%s' "$out" | grep -q "아무도 안 봤다" && r y y '그 커밋이 리뷰를 못 받았다고 알린다' || r y n '그 커밋이 리뷰를 못 받았다고 알린다'
fresh; out=$(GH_CH_CODEX=none GH_CH_CLAUDE=none run); rc=$?
r 1 "$rc" '리뷰가 아예 없으면 멈춘다'

echo "── 봇 둘이 각각 head 를 리뷰했는지 본다 (PR #51) ──"
fresh; out=$(GH_REVIEWED_CLAUDE=0123456789abcdef0123 run); rc=$?
r 1 "$rc" 'claude 가 옛 커밋만 리뷰했으면 멈춘다'
printf '%s' "$out" | grep -q "claude" && r y y '어느 봇이 빠졌는지 알린다' || r y n '어느 봇이 빠졌는지 알린다'

echo "── head 저장소를 대조한다 ──"
fresh; out=$(GH_OWNER=other run); rc=$?
r 1 "$rc" 'PR head 가 다른 저장소면 멈춘다'
r "feature/x" "$(git branch --show-current)" '내 브랜치를 안 지운다'

echo "── 봇 증거가 SHA 없는 채널로만 올 때 (PR #53) ──"
# 실제로 PR #33 은 codex 가 반응만, claude 가 이슈 코멘트만 남겼다.
# 그것이 **현재 head** 를 본 것인지 기계가 알 수 없으므로 자동 통과시키지 않는다.
fresh; out=$(GH_CH_CODEX=reaction GH_CH_CLAUDE=icomment run); rc=$?
r 1 "$rc" 'SHA 없는 채널만 있으면 사람 확인을 요구한다'
printf '%s' "$out" | grep -q "CLEANUP_ALLOW_SHALESS" && r y y '어떻게 넘어가는지 알려준다' || r y n '어떻게 넘어가는지 알려준다'
r "feature/x" "$(git branch --show-current)" '그때는 아무것도 안 지운다'

fresh; out=$(CLEANUP_ALLOW_SHALESS=1 GH_CH_CODEX=reaction GH_CH_CLAUDE=icomment run); rc=$?
r 0 "$rc" '사람이 확인했다고 하면 진행한다'

fresh; out=$(GH_CH_CODEX=comment GH_CH_CLAUDE=review run); rc=$?
r 0 "$rc" '인라인 리뷰 코멘트는 SHA 가 있어 자동으로 받는다'

echo "── 반응 종류를 가른다 ──"
fresh; out=$(GH_CH_CODEX=reaction_eyes GH_CH_CLAUDE=review run); rc=$?
r 1 "$rc" 'eyes(검토 시작)는 완료 증거가 아니다'

echo "── head 저장소를 정확히 대조한다 ──"
fresh; out=$(GH_REPO=work-backup run); rc=$?
r 1 "$rc" 'me/work 와 me/work-backup 을 가른다(부분문자열 아님)'

echo "── 봇 로그인을 정확히 대조한다 (PR #53) ──"
# `claude-review-helper` 같은 아무 계정이 리뷰 하나로 통과시킬 수 없어야 한다.
fresh; out=$(REQUIRED_BOTS="chatgpt-codex-connector[bot] claude[bot]" GH_CH_CLAUDE=none run); rc=$?
r 1 "$rc" '요구한 로그인이 없으면 멈춘다'

echo "── codex 지적 (PR #54) ──"
# merge commit 이 꺼진 저장소에서 --merge 만 두 번 시도하면 Phase 6 이 막힌다.
fresh; out=$(GH_MERGE_OK=false GH_SQUASH_OK=true run); rc=$?
r 0 "$rc" 'merge commit 이 꺼져 있으면 squash 로 떨어진다'
printf '%s' "$out" | grep -q "squash" && r y y '어느 전략을 썼는지 알린다' || r y n '어느 전략을 썼는지 알린다'

# 큐를 기다리는 사이 누가 push 하면 그 커밋을 지우면 안 된다.
fresh
# 원격 브랜치를 다른 커밋으로 옮긴다(다른 사람이 push 한 셈).
printf 'other\n' > o.txt; git add o.txt; git commit -qm "남의 커밋"
git push -q origin feature/x 2>/dev/null
git reset -q --hard HEAD~1                     # 로컬은 리뷰된 커밋으로 되돌린다
out=$(run); rc=$?
r 1 "$rc" '원격이 다른 커밋을 가리키면 안 지운다'
printf '%s' "$out" | grep -q "머지 뒤에 누가 push" && r y y '왜 멈췄는지 알린다' || r y n '왜 멈췄는지 알린다'

echo "── codex 지적 (PR #56) ──"
# 큐 대기 사이 다른 터미널이 로컬에 커밋을 얹으면 그것을 날리면 안 된다.
fresh
git remote set-url --push origin "$R/me/work"
printf 'later\n' > later.txt; git add later.txt; git commit -qm "다른 터미널이 얹은 커밋"
# GH_OID 는 리뷰된(= 하나 전) 커밋으로 둔다.
out=$(GH_OID=$(git rev-parse HEAD~1) run); rc=$?
r 1 "$rc" '로컬이 앞서 있으면 멈춘다(push 안 한 커밋을 안 날린다)'
r "feature/x" "$(git branch --show-current)" '브랜치가 그대로 있다'

echo "── codex 지적 (PR #57) ──"
# --delete-branch 는 머지 직후 로컬·원격을 즉시 지운다. 그러면 뒤의 재검증이
# 지워진 ref 를 재느라 **정상 실행이 매번 실패로 끝난다.**
# grep -c 를 쓴다 — -q 는 매치하자마자 닫혀 SIGPIPE 함정을 부른다.
# 주석은 이 플래그를 **설명**한다 — 세면 안 된다. 명령줄만 본다.
r 0 "$(grep -v '^[[:space:]]*#' "$SCRIPT" | grep -c -- '--delete-branch' || true)" \
   '머지 호출에 --delete-branch 를 쓰지 않는다'

# 원격 삭제는 리뷰된 SHA 에 lease 로 묶는다 — 조회와 삭제 사이의 push 를 막는다.
r 1 "$(grep -c 'force-with-lease' "$SCRIPT" || true)" \
   '원격 삭제를 리뷰된 SHA 에 lease 로 묶는다'

echo
echo "════ 합계: OK $pass / FAIL $fail ════"
[ "$fail" -eq 0 ]
