#!/usr/bin/env bash
# codex 가 P1 로 지적한 셋을 실물로 확인한다.
H="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
source "$(cd "$(dirname "$0")" && pwd)/fixtures.sh"
R=$(mktemp -d)
trap 'rm -rf "$R"' EXIT

pass=0; fail=0
r() { if [ "$1" = "$2" ]; then pass=$((pass+1)); printf '  [OK ] '; else fail=$((fail+1)); printf '  [FAIL] '; fi
     printf '기대 %s / 실제 %s  %s\n' "$1" "$2" "$3"; }
fresh() { rm -rf "$R"; mkdir -p "$R"; cd "$R" || exit 1
    git init -q -b feature/x .; git config user.email t@t.t; git config user.name t
    printf 'base\n' > base.txt; git add base.txt; git commit -qm init; }
sg() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$1" | bash "$H/secret-guard" >/dev/null 2>&1; echo "$?"; }
cg() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$1" | bash "$H/commit-guard"  >/dev/null 2>&1; echo "$?"; }

echo "── P1-1: 따옴표 친 플래그 (셸은 -a 로 넘긴다) ──"
fresh
printf '%s\n' "$AWS_FAKE" >> base.txt
r 2 "$(sg '"git commit \"-a\" -m test"')"      'git commit "-a" -m test'
r 2 "$(sg "\"git commit '--all' -m test\"")"    "git commit '--all' -m test"
fresh
printf '%s\n' "$AWS_FAKE" >> base.txt
r 2 "$(sg '"git commit -m \"-a 옵션 이야기\""')" '메시지 모양과 무관하게 워킹트리를 본다'

echo "── P1-2: 이름이 바뀐 파일 (diff type R) ──"
fresh
printf 'plain\n' > ordinary.txt; git add ordinary.txt; git commit -qm add
git mv ordinary.txt CLAUDE.md
r 2 "$(cg '"git commit -m x"')"                 'git mv 로 CLAUDE.md 가 된 파일 (규칙 9)'
fresh
printf 'cfg\n' > conf.txt; git add conf.txt; git commit -qm add
git mv conf.txt renamed.txt; printf '%s\n' "$AWS_FAKE" >> renamed.txt; git add renamed.txt
r 2 "$(sg '"git commit -m x"')"                 '이름 바뀌고 시크릿이 붙은 파일'

echo "── P1-3: 하위 폴더에서 commit -a ──"
fresh
mkdir -p sub; printf 'cfg\n' > sub/config; git add sub/config; git commit -qm add
printf '%s\n' "$AWS_FAKE" >> sub/config
cd "$R/sub" || exit 1
r 2 "$(sg '"git commit -am x"')"                '하위 폴더 cwd 에서 -a'

echo
echo "════ 합계: OK $pass / FAIL $fail ════"
[ "$fail" -eq 0 ]
