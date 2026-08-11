#!/usr/bin/env bash
# pr-guard 세 갈래 시험. 입력을 이 파일 안에 두는 이유는, 명령줄에 적으면
# 세션의 pr-guard가 시험 문자열을 진짜 명령으로 읽고 시험 자체를 막기 때문이다.
H="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

feed() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$1" | bash "$H/pr-guard" >/dev/null 2>&1; echo "$?"; }

r() { # 기대값 실제값 설명
    local mark="OK "
    [ "$1" = "$2" ] || mark="FAIL"
    printf '  [%s] 기대 %s / 실제 %s  %s\n' "$mark" "$1" "$2" "$3"
}

echo "── 갈래 1: 막아야 할 것이 막히나 (규칙 10 본령) ──"
r 2 "$(feed '"gh pr review 20 --approve"')"                        'gh pr review --approve'
r 2 "$(feed '"gh pr review 20 --comment -b \"고쳐주세요\""')"        'gh pr review --comment'
r 2 "$(feed '"gh pr comment 20 --body \"이 부분 이상합니다\""')"      'gh pr comment (리뷰 내용)'
r 2 "$(feed '"gh issue comment 5 --body \"확인했습니다\""')"          'gh issue comment'
r 2 "$(feed '"gh api repos/o/r/pulls/1/reviews -X POST -f body=x"')" 'gh api로 리뷰 생성'
r 2 "$(feed '"echo hi; gh pr review 20 --approve"')"               '앞에 다른 명령이 붙어도'

echo "── 갈래 2: 통과해야 할 것이 통과하나 ──"
r 0 "$(feed '"gh pr comment 20 --body \"@codex review\""')"        '봇 호출 토큰'
r 0 "$(feed '"gh pr comment 20 --body \"@claude review 한국어로\""')" '봇 호출 + 언어 지시'
r 0 "$(feed '"gh pr list --state open"')"                          'gh pr list'
r 0 "$(feed '"gh pr view 20 --json body"')"                        'gh pr view'
r 0 "$(feed '"gh pr create --title t --body b"')"                  'gh pr create'
r 0 "$(feed '"gh api repos/o/r/pulls/1/reviews"')"                 'gh api 조회(GET)'
r 0 "$(feed '"git commit -m x"')"                                  'gh와 무관한 명령'

echo "── 이번에 여는 자리: PR 설명 수정 (규칙 10과 무관) ──"
r 0 "$(feed '"gh pr edit 20 --body-file /tmp/x.md"')"              'gh pr edit --body-file'
r 0 "$(feed '"gh pr edit 20 --body \"설명을 고친다\""')"             'gh pr edit --body'
r 0 "$(feed '"gh pr edit 20 --title \"제목만\""')"                   'gh pr edit --title'

echo "── 갈래 3: 판정 근거가 없을 때 ──"
r 2 "$(feed '"gh pr review 20"')"                                  '옵션 없는 review'
r 2 "$(feed '"gh pr comment 20"')"                                 '본문 없는 comment (fail-closed)'
r 2 "$(feed '"gh pr comment 20 --body-file /tmp/x.md"')"           '본문을 파일로 넘긴 comment'
r 0 "$(feed '""')"                                                 '빈 명령'
