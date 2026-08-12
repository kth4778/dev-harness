#!/usr/bin/env bash
# skills/pr/scripts/merge-cleanup.sh 의 갈래를 잰다.
#
# gh 를 가짜로 갈아끼워 네트워크 없이 돌린다 — 진짜 PR 을 건드리지 않는다.
ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
SCRIPT="$ROOT/skills/pr/scripts/merge-cleanup.sh"
R=$(mktemp -d); BIN=$(mktemp -d)
trap 'rm -rf "$R" "$BIN"' EXIT

pass=0; fail=0
r() { if [ "$1" = "$2" ]; then pass=$((pass+1)); printf '  [OK ] '; else fail=$((fail+1)); printf '  [FAIL] '; fi
     printf '기대 %s / 실제 %s  %s\n' "$1" "$2" "$3"; }

# 가짜 gh. GH_MERGE_RC·GH_STATE 로 행동을 바꾼다.
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
case "$2" in
  merge) [ "${GH_DELETE_REJECT:-0}" = "1" ] && printf '%s\n' "$*" | grep -q -- --delete-branch && exit 1
         exit "${GH_MERGE_RC:-0}" ;;
  view)  printf '%s\n' "${GH_STATE:-MERGED}" ;;
esac
GH
chmod +x "$BIN/gh"; export PATH="$BIN:$PATH"

# 원격 있는 저장소를 만들고 기능 브랜치에 선다.
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

echo "── 정상 경로 ──"
fresh; out=$(bash "$SCRIPT" 1 main 2>&1); rc=$?
r 0 "$rc" '머지되고 정리까지 끝난다'
r "main" "$(git rev-parse --abbrev-ref HEAD)" '통합 브랜치로 옮겨져 있다'
r "" "$(git branch --list feature/x)" '로컬 브랜치가 지워졌다'
r "" "$(git ls-remote --heads origin feature/x)" '원격 브랜치가 지워졌다'

echo "── 원격에 이미 없을 때(자동 삭제 설정) ──"
fresh; git push -q origin --delete feature/x 2>/dev/null
out=$(bash "$SCRIPT" 1 main 2>&1); rc=$?
r 0 "$rc" '이미 없으면 성공으로 친다'
r "" "$(git branch --list feature/x)" '로컬은 그래도 지운다'

echo "── 머지가 안 끝났을 때 ──"
fresh; out=$(CLEANUP_WAIT_SEC=2 CLEANUP_POLL_SEC=1 GH_DELETE_REJECT=1 GH_STATE=OPEN bash "$SCRIPT" 1 main 2>&1); rc=$?
r 1 "$rc" '큐가 안 끝나면 실패로 끝난다'
r "feature/x" "$(git rev-parse --abbrev-ref HEAD)" '브랜치를 안 지우고 그대로 둔다'

echo "── PR 이 닫혔을 때 ──"
fresh; out=$(CLEANUP_WAIT_SEC=2 CLEANUP_POLL_SEC=1 GH_DELETE_REJECT=1 GH_STATE=CLOSED bash "$SCRIPT" 1 main 2>&1); rc=$?
r 1 "$rc" '닫혔으면 정리하지 않는다'
r "feature/x" "$(git branch --show-current)" '로컬 브랜치가 남아 있다'

echo "── 큐에 못 넣었을 때 ──"
fresh; out=$(GH_MERGE_RC=1 bash "$SCRIPT" 1 main 2>&1); rc=$?
r 1 "$rc" '머지 요청이 실패하면 즉시 멈춘다'
printf '%s' "$out" | grep -q "큐에 넣지 못했다" && r y y '이유를 알린다' || r y n '이유를 알린다'

echo "── merge queue 우회 ──"
fresh; out=$(CLEANUP_WAIT_SEC=2 CLEANUP_POLL_SEC=1 GH_DELETE_REJECT=1 GH_STATE=MERGED bash "$SCRIPT" 1 main 2>&1); rc=$?
r 0 "$rc" '--delete-branch 가 거부돼도 플래그 없이 넣고 정리한다'
r "" "$(git branch --list feature/x)" '정리가 끝났다'

echo
echo "════ 합계: OK $pass / FAIL $fail ════"
[ "$fail" -eq 0 ]
