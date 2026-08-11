#!/usr/bin/env bash
# 봇 리뷰가 찾아낸 셸 문법 코너들.
#
# 한때 이 시험들은 「`git commit -a` 인지 정확히 가려내는가」를 쟀다. 그 판정을
# 정규식으로 맞히려다 다섯 라운드 연속 실패해서(P1 3→1→2→3, 줄지 않았다)
# 판정 자체를 버렸다. 지금은 명령 모양과 무관하게 인덱스와 워킹트리를 둘 다 본다.
#
# **그래서 여기 있는 문법들은 전부 「막힌다」가 정답이다.** 어느 하나가 통과로
# 바뀌면 누군가 판정을 되살렸다는 뜻이고, 그 순간 P1 이 다시 열린다.
H="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
source "$(cd "$(dirname "$0")" && pwd)/fixtures.sh"
R=$(mktemp -d)
trap 'rm -rf "$R"' EXIT

pass=0; fail=0
r() { if [ "$1" = "$2" ]; then pass=$((pass+1)); printf '  [OK ] '; else fail=$((fail+1)); printf '  [FAIL] '; fi
     printf '기대 %s / 실제 %s  %s\n' "$1" "$2" "$3"; }
fresh() { rm -rf "$R"; mkdir -p "$R"; cd "$R" || exit 1
    git init -q -b feature/x .; git config user.email t@t.t; git config user.name t
    git config core.fileMode "${1:-false}"
    printf 'base\n' > base.txt; git add base.txt; git commit -qm init; mkdir -p hooks; }
sg() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$1" | bash "$H/secret-guard" >/dev/null 2>&1; echo "$?"; }
cg() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$1" | bash "$H/commit-guard"  >/dev/null 2>&1; echo "$?"; }

# 추적 파일에 시크릿을 넣되 스테이징하지 않는다. 옛 판이라면 명령 모양에 따라
# 인덱스만 보고 놓쳤을 상태다.
leak_unstaged() { fresh "$1"; printf '%s\n' "$AWS_FAKE" >> base.txt; }

echo "── 어떤 문법으로 써도 막힌다 (전부 2) ──"
leak_unstaged; r 2 "$(sg '"git commit -am x"')"                        '-am'
leak_unstaged; r 2 "$(sg '"git commit -a -m x"')"                      '-a 따로'
leak_unstaged; r 2 "$(sg '"git commit --all -m x"')"                   '--all'
leak_unstaged; r 2 "$(sg '"git commit -m x"')"                         '-a 없는 평범한 커밋'
leak_unstaged; r 2 "$(sg '"git commit \"-a\" -m x"')"                  '따옴표 친 "-a"'
leak_unstaged; r 2 "$(sg '"git commit -\"a\" -m x"')"                  '부분 따옴표 -"a"'
leak_unstaged; r 2 "$(sg "\"git commit '-'a -m x\"")"                  "따옴표 접두 '-'a"
leak_unstaged; r 2 "$(sg '"git commit -m foo\\;bar -a"')"            '이스케이프된 세미콜론'
leak_unstaged; r 2 "$(sg '"git commit -m $'\''foo;bar'\'' -a"')"       'ANSI-C 인용'
leak_unstaged; r 2 "$(sg '"out=$(git commit -am x)"')"                 '명령 치환 안의 커밋'
leak_unstaged; r 2 "$(sg '"git commit -mbar -a"')"                     '붙은 인자 -mbar'
leak_unstaged; r 2 "$(sg '"git commit -qm \"docs: -a 옵션\""')"        '묶음 플래그 + 메시지'
leak_unstaged; r 2 "$(sg '"git commit -m \"-a\""')"                    '메시지가 -a 모양'
leak_unstaged; r 2 "$(sg '"git commit -m \"say \\\"x; y\\\"\" -a"')"   '이스케이프 따옴표 속 세미콜론'
leak_unstaged; r 2 "$(sg "\"git -C $R commit -m x\"")"                 'git -C'
leak_unstaged; r 2 "$(sg '"git --no-pager commit -m x"')"              '옵션이 낀 커밋'
leak_unstaged; r 2 "$(sg '"echo hi; git commit -m x"')"                '앞에 다른 명령'

echo "── 하위 폴더에서도 (전부 2) ──"
fresh; mkdir -p sub; printf 'cfg\n' > sub/config; git add sub/config; git commit -qm add
printf '%s\n' "$AWS_FAKE" >> sub/config; cd "$R/sub" || exit 1
r 2 "$(sg '"git commit -am x"')"                                       '하위 폴더 cwd'

echo "── 통과해야 할 것 (전부 0) ──"
fresh; printf 'just code\n' > ok.txt; git add ok.txt
r 0 "$(sg '"git commit -m x"')"                                        '깨끗한 파일'
r 0 "$(sg '"git commit -am x"')"                                       '깨끗한 파일 + -a'
r 0 "$(sg '"git status"')"                                             '커밋 아닌 명령'
fresh; r 0 "$(sg '"git commit -m x"')"                                 '바뀐 것이 없다'
fresh; printf '%s\n' "$AWS_FAKE" > untracked.txt
r 0 "$(sg '"git commit -am x"')"                                       '추적 안 된 새 파일은 커밋 대상이 아니다'

echo "── 실행 권한 비트 ──"
fresh; printf '#!/usr/bin/env bash\n' > hooks/h1; git add hooks/h1
r 2 "$(cg '"git commit -m x"')"                                        '새 훅이 100644'
fresh; printf '#!/usr/bin/env bash\n' > hooks/h2; git add hooks/h2; git update-index --chmod=+x hooks/h2
r 0 "$(cg '"git commit -m x"')"                                        '100755 로 세우면 통과'
# core.fileMode 가 false 의 다른 표기(no·0·False)일 때. 인덱스가 100644 면
# 워킹트리가 실행 가능해도 100644 로 커밋된다 — 막아야 한다.
fresh; printf '#!/usr/bin/env bash\n' > hooks/h3; git add hooks/h3; git commit -qm add
git config core.fileMode no; chmod +x hooks/h3; printf 'touch\n' >> hooks/h3
r 2 "$(cg '"git commit -am x"')"                                       'core.fileMode=no 를 false 로 읽는다'
# core.fileMode=true 에서 -a 는 실행 비트 변경도 함께 스테이징한다.
fresh true; printf '#!/usr/bin/env bash\n' > hooks/h4; chmod +x hooks/h4
git add hooks/h4; git commit -qm add; chmod -x hooks/h4
r 2 "$(cg '"git commit -am x"')"                                       'fileMode=true 에서 비트를 잃은 훅'
fresh; printf '#!/usr/bin/env bash\n' > hooks/한글훅; git add hooks/한글훅
r 2 "$(cg '"git commit -m x"')"                                        '비ASCII 이름도 검사한다'
fresh; printf '{}\n' > hooks/hooks.json; git add hooks/hooks.json
r 0 "$(cg '"git commit -m x"')"                                        '확장자 있는 파일은 대상 아님'

echo "── 규칙 9 는 인덱스만 본다 ──"
fresh; mkdir -p _workspace; printf 'x\n' > _workspace/a.md; git add -f _workspace/a.md
r 2 "$(cg '"git commit -m x"')"                                        '_workspace 스테이징'
fresh; mkdir -p .harness; printf 'x\n' > .harness/root; git add -f .harness/root
r 2 "$(cg '"git commit -m x"')"                                        '.harness 스테이징'
# 넓히면 .claude/ 가 세션 내내 워킹트리에 있어 모든 커밋이 막힌다. 그래서 규칙 9
# 만은 인덱스에 머문다 — 추적 중인 AI 파일은 .gitignore 로 잡을 문제다.
fresh; printf 'x\n' > CLAUDE.md; git add -f CLAUDE.md; git commit -qm add
printf 'y\n' >> CLAUDE.md
r 0 "$(cg '"git commit -am x"')"                                       '추적 중인 CLAUDE.md 수정은 인덱스에 없으면 통과'


echo "── 봇 4차 지적 (PR #27) ──"
# P1: 스테이징한 뒤 워킹트리를 HEAD 로 되돌리면 git diff HEAD 에서 사라진다.
fresh
printf '%s\n' "$AWS_FAKE" >> base.txt; git add base.txt
git checkout-index -f -- base.txt 2>/dev/null || true
printf 'base\n' > base.txt                             # 워킹트리는 HEAD 와 같게
r 2 "$(sg '"git commit -m x"')"                        'P1 인덱스에만 있는 시크릿'
# P1: HEAD 가 없는 저장소의 최초 커밋.
rm -rf "$R"; mkdir -p "$R"; cd "$R" || exit 1
git init -q -b feature/x .; git config user.email t@t.t; git config user.name t
git config core.fileMode false; mkdir -p hooks
printf '%s\n' "$AWS_FAKE" > leak.txt; git add leak.txt
r 2 "$(sg '"git commit -m first"')"                    'P1 최초 커밋(HEAD 없음)'
printf '#!/usr/bin/env bash\n' > hooks/h5; git add hooks/h5
r 2 "$(cg '"git commit -m first"')"                    'P1 최초 커밋의 100644 훅'
# P2: 훅이 심볼릭 링크로 바뀌면 git 은 120000 으로 기록한다.
fresh true
printf '#!/usr/bin/env bash\n' > hooks/real; chmod +x hooks/real
git add hooks/real; git commit -qm add
rm hooks/real; ln -s /nonexistent hooks/real
r 2 "$(cg '"git commit -am x"')"                       'P2 훅이 심볼릭 링크로 바뀌었다'
# P2: 따옴표 안의 글자는 실행되지 않는다.
fresh; git checkout -q -b main 2>/dev/null || git branch -qm main
r 0 "$(cg '"echo \"git commit \""')"                   'P2 echo 안의 git commit 은 실행이 아니다'

echo
echo "════ 합계: OK $pass / FAIL $fail ════"
[ "$fail" -eq 0 ]
