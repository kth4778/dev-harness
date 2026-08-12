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
case "$2" in
  view)
    case "$*" in
      *headRefName*) printf '%s\n' "${GH_HEAD:-feature/x}" ;;
      *baseRefName*) printf '%s\n' "${GH_BASE:-main}" ;;
      *headRefOid*)  printf '%s\n' "${GH_OID:-abc1234567890}" ;;
      *state*)       printf '%s\n' "${GH_STATE:-MERGED}" ;;
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
    git init -q --bare -b main "$R/remote"
    git clone -q "$R/remote" "$R/work" 2>/dev/null
    cd "$R/work" || exit 1
    git config user.email t@t.t; git config user.name t
    printf 'base\n' > base.txt; git add base.txt; git commit -qm init
    git push -q origin main 2>/dev/null; git remote set-head origin main 2>/dev/null
    git switch -qc feature/x
    printf 'x\n' > f.txt; git add f.txt; git commit -qm work
    git push -q -u origin feature/x 2>/dev/null
}
run() { CLEANUP_WAIT_SEC=2 CLEANUP_POLL_SEC=1 bash "$SCRIPT" 1 2>&1; }

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

echo
echo "════ 합계: OK $pass / FAIL $fail ════"
[ "$fail" -eq 0 ]
