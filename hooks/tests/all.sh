#!/usr/bin/env bash
# 훅 8개가 디스패처 경유로 전부 정상 종료하는지, 차단 갈래가 살아 있는지 본다.
#
# 값을 찍기만 하면 안 된다. 예전 판은 종료 코드를 출력에 끼워 넣기만 하고
# 기대값과 비교하지 않아서, 디스패처가 깨져도 suite 가 0 으로 끝났다
# (codex, PR #24). 여기서 세는 것이 run-all.sh 의 총계에도 들어간다.
H="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
source "$(cd "$(dirname "$0")" && pwd)/fixtures.sh"
R=$(mktemp -d)
trap 'rm -rf "$R"' EXIT

pass=0; fail=0
r() { if [ "$1" = "$2" ]; then pass=$((pass+1)); printf '  [OK ] '; else fail=$((fail+1)); printf '  [FAIL] '; fi
     printf '기대 %s / 실제 %s  %s\n' "$1" "$2" "$3"; }

cd "$R" || exit 1
git init -q -b main .; git config user.email t@t.t; git config user.name t
printf 'base\n' > base.txt; git add base.txt; git commit -qm init

d() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$2" | "$H/run-hook.cmd" "$1" >/dev/null 2>&1; echo "$?"; }

echo "── 무해한 명령에 훅 8개가 조용히 통과하나 ──"
for h in pr-guard commit-guard secret-guard stamp-guard worktree-guard test-coverage-notice; do
    r 0 "$(d "$h" '"echo hello"')" "$h"
done
r 0 "$(printf '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x.txt"}}' | "$H/run-hook.cmd" workspace-guard >/dev/null 2>&1; echo $?)" "workspace-guard"
r 0 "$(printf '{}' | "$H/run-hook.cmd" session-start >/dev/null 2>&1; echo $?)" "session-start"

echo "── 차단이 실제로 나나 ──"
printf '%s\n' "$AWS_FAKE" > leak.txt; git add leak.txt
r 2 "$(d secret-guard '"git commit -m x"')"        "secret-guard"
r 2 "$(d commit-guard '"git commit -m x"')"        "commit-guard (main 직접 커밋)"
r 2 "$(d pr-guard '"gh pr review 1 --approve"')"   "pr-guard"
mkdir -p .harness; printf 'x\n' > .harness/agents-running
r 2 "$(d worktree-guard '"git switch main"')"      "worktree-guard"
rm -f .harness/agents-running

echo
echo "════ 합계: OK $pass / FAIL $fail ════"
[ "$fail" -eq 0 ]
