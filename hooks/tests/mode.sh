#!/usr/bin/env bash
# commit-guard 의 실행 권한 비트 검사.
H="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
R=$(mktemp -d)
trap 'rm -rf "$R"' EXIT

pass=0; fail=0
r() { if [ "$1" = "$2" ]; then pass=$((pass+1)); printf '  [OK ] '; else fail=$((fail+1)); printf '  [FAIL] '; fi
     printf '기대 %s / 실제 %s  %s\n' "$1" "$2" "$3"; }
fresh() { rm -rf "$R"; mkdir -p "$R"; cd "$R" || exit 1
    git init -q -b feature/x .; git config user.email t@t.t; git config user.name t
    git config core.fileMode false
    printf 'base\n' > base.txt; git add base.txt; git commit -qm init; mkdir -p hooks; }
cg() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$1" | bash "$H/commit-guard" >/dev/null 2>&1; echo "$?"; }

echo "── 막아야 할 것 ──"
fresh
printf '#!/usr/bin/env bash\n' > hooks/new-guard; git add hooks/new-guard      # 100644 로 들어간다
r 2 "$(cg '"git commit -m x"')"                    '확장자 없는 훅이 100644'

echo "── 통과해야 할 것 ──"
fresh
printf '#!/usr/bin/env bash\n' > hooks/new-guard; git add hooks/new-guard
git update-index --chmod=+x hooks/new-guard
r 0 "$(cg '"git commit -m x"')"                    '같은 파일을 100755 로 세우면'
fresh
printf '{}\n' > hooks/hooks.json; git add hooks/hooks.json
r 0 "$(cg '"git commit -m x"')"                    'hooks.json 은 실행 파일이 아니다'
fresh
printf 'doc\n' > hooks/README.md; git add hooks/README.md
r 0 "$(cg '"git commit -m x"')"                    '확장자가 있는 파일은 대상 아님'
fresh
printf 'code\n' > src.java; git add src.java
r 0 "$(cg '"git commit -m x"')"                    'hooks/ 밖의 파일'
fresh
r 0 "$(cg '"git status"')"                         '커밋 아닌 명령'

echo
echo "════ 합계: OK $pass / FAIL $fail ════"
[ "$fail" -eq 0 ]
