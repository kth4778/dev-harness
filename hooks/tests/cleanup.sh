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
ch()  { case "$1" in codex) printf '%s' "${GH_CH_CODEX:-review}" ;;
                     claude) printf '%s' "${GH_CH_CLAUDE:-review}" ;; esac; }
oid() { case "$1" in codex) printf '%s' "${GH_REVIEWED:-$GH_OID}" ;;
                     claude) printf '%s' "${GH_REVIEWED_CLAUDE:-${GH_REVIEWED:-$GH_OID}}" ;; esac; }
case "$1" in
  api)
    case "$*" in
      */commits/*)  printf '%s\n' "${GH_HEAD_TIME:-2020-01-01T00:00:00Z}"; exit 0 ;;
      */pulls/*/reviews*)
        for b in codex claude; do
          printf '%s' "$*" | grep -q "\"$b\"" || continue
          [ "$(ch $b)" = review ] && printf '%s\n' "$(oid $b)"
        done; exit 0 ;;
      */pulls/*/comments*)
        for b in codex claude; do
          printf '%s' "$*" | grep -q "\"$b\"" || continue
          [ "$(ch $b)" = comment ] && printf '%s\n' "$(oid $b)"
        done; exit 0 ;;
      */issues/*/comments*)
        for b in codex claude; do
          printf '%s' "$*" | grep -q "\"$b\"" || continue
          [ "$(ch $b)" = icomment ] && printf '%s\n' "${GH_EV_TIME:-2030-01-01T00:00:00Z}"
        done; exit 0 ;;
      */issues/*/reactions*)
        for b in codex claude; do
          printf '%s' "$*" | grep -q "\"$b\"" || continue
          [ "$(ch $b)" = reaction ] && printf '%s\n' "${GH_EV_TIME:-2030-01-01T00:00:00Z}"
        done; exit 0 ;;
      *) printf '%s\n' "${GH_BASE_NWO:-}" ; exit 0 ;;   # base repo full_name
    esac ;;
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

echo "── 봇 증거가 리뷰 아닌 채널로 올 때 (PR #52) ──"
# 실제로 PR #33 은 codex 가 반응만, claude 가 이슈 코멘트만 남겼다.
fresh; out=$(GH_CH_CODEX=reaction GH_CH_CLAUDE=icomment run); rc=$?
r 0 "$rc" '반응·코멘트만 있어도 통과한다'
r "" "$(git branch --list feature/x)" '정리가 끝났다'

fresh; out=$(GH_CH_CODEX=comment GH_CH_CLAUDE=review run); rc=$?
r 0 "$rc" '인라인 리뷰 코멘트도 증거로 본다'

# head 보다 **앞선** 시각의 반응은 그 커밋을 본 것이 아니다.
fresh; out=$(GH_CH_CODEX=reaction GH_EV_TIME=2019-01-01T00:00:00Z run); rc=$?
r 1 "$rc" 'head 보다 앞선 반응은 증거가 아니다'

echo "── head 저장소를 정확히 대조한다 ──"
fresh; out=$(GH_REPO=work-backup run); rc=$?
r 1 "$rc" 'me/work 와 me/work-backup 을 가른다(부분문자열 아님)'

echo
echo "════ 합계: OK $pass / FAIL $fail ════"
[ "$fail" -eq 0 ]
