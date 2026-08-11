#!/usr/bin/env bash
# commit-guard · secret-guard 세 갈래 시험.
# 사용법: probe-guards.sh <훅폴더>   (버릴 저장소를 매번 새로 만든다)
H="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
source "$(cd "$(dirname "$0")" && pwd)/fixtures.sh"
R=$(mktemp -d)
trap 'rm -rf "$R"' EXIT

pass=0; fail=0
r() { # 기대 실제 설명
    if [ "$1" = "$2" ]; then pass=$((pass+1)); printf '  [OK ] '; else fail=$((fail+1)); printf '  [FAIL] '; fi
    printf '기대 %s / 실제 %s  %s\n' "$1" "$2" "$3"
}

fresh() { # <브랜치>
    rm -rf "$R"; mkdir -p "$R"; cd "$R" || exit 1
    git init -q -b "${1:-feature/x}" .
    git config user.email t@t.t; git config user.name t
    printf 'base\n' > base.txt; git add base.txt; git commit -qm init
}

sg() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$1" | bash "$H/secret-guard" >/dev/null 2>&1; echo "$?"; }
cg() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$1" | bash "$H/commit-guard"  >/dev/null 2>&1; echo "$?"; }

echo "════ secret-guard ════"
echo "── 갈래 1: 막아야 할 것이 막히나 ──"
fresh
printf '%s\n' "$AWS_FAKE" > leak.txt; git add leak.txt
r 2 "$(sg '"git commit -m x"')"                       '스테이징된 시크릿'
r 2 "$(sg "\"git -C $R commit -m x\"")"               'git -C 로 커밋'
r 2 "$(sg '"git --no-pager commit -m x"')"            '옵션이 낀 커밋'
r 2 "$(sg "\"cd $R && git commit -m x\"")"            '앞머리 cd'
r 2 "$(sg '"echo hi; git commit -m x"')"              '앞에 다른 명령'

echo "── 갈래 3(새로 막는 것): commit -a 로 스테이징을 건너뛸 때 ──"
fresh
printf '%s\n' "$AWS_FAKE" >> base.txt      # 추적 파일을 고치기만 하고 add 안 함
r 2 "$(sg '"git commit -am x"')"                      '-am 묶음 플래그'
r 2 "$(sg '"git commit -a -m x"')"                    '-a 따로'
r 2 "$(sg '"git commit --all -m x"')"                 '--all'
r 2 "$(sg '"git commit -m x"')"                       '명령 모양과 무관하게 워킹트리도 본다'

echo "── 갈래 2: 통과해야 할 것이 통과하나 ──"
fresh
printf 'just code\n' > ok.txt; git add ok.txt
r 0 "$(sg '"git commit -m x"')"                       '깨끗한 파일'
r 0 "$(sg '"git commit -am x"')"                      '깨끗한 파일 + -a'
r 0 "$(sg '"git status"')"                            '커밋 아닌 명령'
r 0 "$(sg '"git log --oneline"')"                     'git log'
fresh
r 0 "$(sg '"git commit -m x"')"                       '스테이징 없음'
fresh
printf '%s\n' "$AWS_FAKE" > untracked.txt        # 추적 안 되는 새 파일
r 0 "$(sg '"git commit -am x"')"                      '-a 는 추적 안 된 새 파일을 안 담는다'
fresh
r 0 "$(sg '"git commit -m \"-a 옵션 이야기\""')"        '메시지 속 -a 를 플래그로 읽지 않는다'
fresh
printf '%s\n' "$AWS_FAKE" >> base.txt; git add base.txt
git checkout -q -- /dev/null 2>/dev/null
printf 'clean again\n' > base.txt                      # 인덱스=시크릿, 워킹트리=깨끗
r 2 "$(sg '"git commit -m x"')"                       '인덱스 쪽이 커밋된다'
r 2 "$(sg '"git commit -am x"')"                      '인덱스가 깨끗해도 워킹트리에 있으면 막는다'

echo
echo "════ commit-guard ════"
echo "── 규칙 1: 보호 브랜치 ──"
fresh main
r 2 "$(cg '"git commit -m x"')"                       'main 에서 커밋'
fresh develop
r 2 "$(cg '"git commit -m x"')"                       'develop 에서 커밋'
fresh master
r 2 "$(cg "\"git -C $R commit -m x\"")"               'git -C 로 master 에 커밋'
fresh feature/x
r 0 "$(cg '"git commit -m x"')"                       'feature 브랜치는 통과'

echo "── 규칙 9: AI 산출물 ──"
fresh
mkdir -p _workspace; printf 'x\n' > _workspace/a.md; git add -f _workspace/a.md
r 2 "$(cg '"git commit -m x"')"                       '_workspace 스테이징'
fresh
printf 'x\n' > CLAUDE.md; git add -f CLAUDE.md; git commit -qm "add"   # 이미 추적 중
printf 'y\n' >> CLAUDE.md                                              # 고치기만 함
r 2 "$(cg '"git commit -am x"')"                      '추적 중인 CLAUDE.md 를 -a 로 커밋'
r 2 "$(cg '"git commit -m x"')"                       '[대조] -a 가 없어도 워킹트리 변경을 본다'
fresh
printf 'code\n' > src.java; git add src.java
r 0 "$(cg '"git commit -m x"')"                       '평범한 소스'
r 0 "$(cg '"git status"')"                            '커밋 아닌 명령'

echo
echo "════ 합계: OK $pass / FAIL $fail ════"
[ "$fail" -eq 0 ]
