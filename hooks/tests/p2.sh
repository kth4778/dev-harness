#!/usr/bin/env bash
# codex 가 PR #23 에 P2 로 지적한 다섯을 실물로 확인한다.
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

echo "── P2-2: 뒤따르는 명령의 따옴표를 플래그로 읽는다 (거짓 차단) ──"
fresh
printf '%s\n' "$AWS_FAKE" >> base.txt        # 워킹트리에만, 스테이징 안 함
printf 'clean\n' > ok.txt; git add ok.txt          # 커밋될 것은 깨끗하다
r 0 "$(sg '"git commit -m ok && printf x \"-a\""')"  '뒤 명령의 "-a" 는 커밋 플래그가 아니다'
r 0 "$(sg '"git commit -m ok; echo \"--all\""')"     '세미콜론 뒤의 --all'

echo "── P2-4: -m 토큰 경계 (거짓 통과) ──"
fresh
printf '%s\n' "$AWS_FAKE" >> base.txt
r 2 "$(sg '"git commit --template=foo-m -a -m x"')" '--template=foo-m 의 -m 을 옵션으로 오인하면 안 된다'

echo "── P2-1: core.fileMode=true 에서 -a 가 mode 변경을 스테이징 ──"
fresh true
printf '#!/usr/bin/env bash\n' > hooks/h1; chmod +x hooks/h1
git add hooks/h1; git commit -qm add                # 100755 로 들어감
chmod -x hooks/h1                                   # 실행 비트를 잃음
r 2 "$(cg '"git commit -am x"')"                    '-a 가 100644 로 기록할 참인데 인덱스는 아직 100755'

echo "── P2-5: 비ASCII 훅 이름 (quotePath) ──"
fresh
printf '#!/usr/bin/env bash\n' > hooks/한글훅; git add hooks/한글훅
r 2 "$(cg '"git commit -m x"')"                     '이름이 한글인 훅도 100644 면 막는다'

echo "── P2-3: .harness/ 가 규칙 9 대상인가 ──"
fresh
mkdir -p .harness; printf 'x\n' > .harness/root; git add -f .harness/root
r 2 "$(cg '"git commit -m x"')"                     '.harness/ 스테이징'

echo "── 회귀: 여전히 통과해야 할 것 ──"
fresh
printf '%s\n' "$AWS_FAKE" >> base.txt
r 2 "$(sg '"git commit -am x"')"                    '진짜 -am 은 여전히 막는다'
r 2 "$(sg '"git commit \"-a\" -m x"')"              '따옴표 친 -a 도 여전히 막는다'
r 0 "$(sg '"git commit -m \"-a 이야기\""')"          '메시지 속 -a 는 여전히 아니다'
fresh
printf '#!/usr/bin/env bash\n' > hooks/h2; git add hooks/h2
git update-index --chmod=+x hooks/h2
r 0 "$(cg '"git commit -m x"')"                     '100755 훅은 통과'


echo "── claude 봇 지적 (PR #23) ──"
fresh
mkdir -p sub; printf '#!/usr/bin/env bash\n' > hooks/h3; git add hooks/h3   # 100644
cd "$R/sub" || exit 1
r 2 "$(cg "\"cd $R/sub && git commit -m x\"")"      '하위 폴더 cwd 에서 실행비트 검사'
fresh
printf '%s\n' "$AWS_FAKE" >> base.txt                # 워킹트리에만
printf 'clean\n' > ok.txt; git add ok.txt            # 커밋될 것은 깨끗
r 0 "$(sg '"git commit -qm \"docs: -a 옵션 설명\""')" '묶음 플래그 -qm 뒤 메시지 속 -a'
r 0 "$(sg '"git commit -m \"note: \\\"quoted\\\" -a leaks\""')" '메시지 속 이스케이프 따옴표 뒤 -a'
r 2 "$(sg '"git commit -qam x"')"                    '[대조] -qam 은 진짜 -a 다'


echo "── codex 2차 지적 (PR #24) ──"
fresh
printf '%s\n' "$AWS_FAKE" >> base.txt                # 워킹트리에만
printf 'clean\n' > ok.txt; git add ok.txt            # 커밋될 것은 깨끗
r 0 "$(sg '"git commit -m \"-a\""')"                 '메시지가 정확히 -a 모양이어도 플래그가 아니다'
r 0 "$(sg '"git commit -qm \"--all\""')"             '묶음 플래그 뒤 메시지가 --all 모양'
fresh
printf '%s\n' "$AWS_FAKE" >> base.txt                # 워킹트리에만, -a 로 커밋될 것
r 2 "$(sg '"git commit -m \"say \\\"x; y\\\"\" -a"')" '이스케이프 따옴표 속 세미콜론 뒤의 진짜 -a'
# core.fileMode 가 false 면 git 은 워킹트리 비트를 무시한다. 인덱스에 100644 로
# 든 훅은 워킹트리가 실행 가능해도 100644 로 커밋된다 — 막아야 한다.
# `no`·`0`·`False` 를 참으로 읽으면 워킹트리 쪽(100755)을 보고 통과시킨다.
fresh
printf '#!/usr/bin/env bash\n' > hooks/h4
git add hooks/h4; git commit -qm add                 # 인덱스에 100644
git config core.fileMode no                          # false 의 다른 표기
chmod +x hooks/h4                                    # 워킹트리만 실행 가능
printf 'touch\n' >> hooks/h4                         # -a 가 담도록 내용도 바꾼다
r 2 "$(cg '"git commit -am x"')"                     'core.fileMode=no 를 false 로 읽어야 100644 를 본다'


echo "── codex 3차 지적 (PR #25) ──"
fresh
printf '%s\n' "$AWS_FAKE" >> base.txt                # 워킹트리에만, -a 로 커밋될 것
r 2 "$(sg '"git commit -m foo\\;bar -a"')"         'P1 이스케이프된 세미콜론은 구분자가 아니다'
fresh
printf '%s\n' "$AWS_FAKE" >> base.txt
r 2 "$(sg '"git commit -\"a\" -m x"')"               'P1 부분 따옴표 -"a" 는 셸이 -a 로 잇는다'
r 2 "$(sg '"git commit --\"all\" -m x"')"            'P1 부분 따옴표 --"all"'
fresh
printf '%s\n' "$AWS_FAKE" >> base.txt                # 워킹트리에만
printf 'clean\n' > ok.txt; git add ok.txt            # 커밋될 것은 깨끗
r 0 "$(sg '"git commit -m -a"')"                     '따옴표 없는 -m 인자가 -a 모양'
r 0 "$(sg '"git commit --message -a"')"              '따옴표 없는 --message 인자'

echo
echo "════ 합계: OK $pass / FAIL $fail ════"
[ "$fail" -eq 0 ]
