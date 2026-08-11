#!/usr/bin/env bash
# 훅 8개가 디스패처 경유로 전부 정상 종료하는지, 차단 갈래가 살아 있는지 본다.
H="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
source "$(cd "$(dirname "$0")" && pwd)/fixtures.sh"
R=$(mktemp -d)
trap 'rm -rf "$R"' EXIT
rm -rf "$R"; mkdir -p "$R"; cd "$R" || exit 1
git init -q -b main .; git config user.email t@t.t; git config user.name t
printf 'base\n' > base.txt; git add base.txt; git commit -qm init

d() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$2" | "$H/run-hook.cmd" "$1" >/dev/null 2>&1; echo "$?"; }

echo "── 디스패처 경유 · 무해한 명령에 훅 8개가 조용히 통과하나 (전부 0) ──"
for h in pr-guard commit-guard secret-guard stamp-guard worktree-guard test-coverage-notice; do
    printf '  %-22s → %s\n' "$h" "$(d "$h" '"echo hello"')"
done
printf '  %-22s → %s\n' "workspace-guard" "$(printf '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x.txt"}}' | "$H/run-hook.cmd" workspace-guard >/dev/null 2>&1; echo $?)"
printf '  %-22s → %s\n' "session-start" "$(printf '{}' | "$H/run-hook.cmd" session-start >/dev/null 2>&1; echo $?)"

echo "── 디스패처 경유 · 차단이 실제로 나나 (전부 2) ──"
printf '%s\n' "$AWS_FAKE" > leak.txt; git add leak.txt
printf '  %-22s → %s\n' "secret-guard"  "$(d secret-guard '"git commit -m x"')"
printf '  %-22s → %s\n' "commit-guard"  "$(d commit-guard '"git commit -m x"')"
printf '  %-22s → %s\n' "pr-guard"      "$(d pr-guard '"gh pr review 1 --approve"')"
printf 'x\n' > .harness-agents-marker
mkdir -p .harness; printf 'x\n' > .harness/agents-running
printf '  %-22s → %s\n' "worktree-guard" "$(d worktree-guard '"git switch main"')"
rm -f .harness/agents-running
