#!/usr/bin/env bash
# pr-guard 세 갈래 시험. 입력을 이 파일 안에 두는 이유는, 명령줄에 적으면
# 세션의 pr-guard가 시험 문자열을 진짜 명령으로 읽고 시험 자체를 막기 때문이다.
H="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

feed() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$1" | bash "$H/pr-guard" >/dev/null 2>&1; echo "$?"; }

pass=0; fail=0
r() { # 기대값 실제값 설명
    local mark="OK "
    if [ "$1" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); mark="FAIL"; fi
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
r 2 "$(feed '"gh pr comment 20 --body-file /tmp/없는파일.md"')"     '못 읽는 파일은 막는다(fail-closed)'
r 0 "$(feed '""')"                                                 '빈 명령'

echo "── 거짓 차단 (2026-08-13 실물) ──"
# 홑따옴표는 셸에서 백틱·$ 가 안 먹혀 오히려 권장되는 인용법이다. 그런데
# 쌍따옴표만 읽어서 본문이 비었고, fail-closed 로 봇 호출이 막혔다.
r 0 "$(feed $'"gh pr comment 57 --body \'@codex review 한국어로\'"')"  '홑따옴표로 감싼 봇 토큰'
r 2 "$(feed $'"gh pr comment 57 --body \'이 부분이 틀렸습니다\'"')"    '홑따옴표라도 리뷰 내용은 막는다'
r 0 "$(feed '"gh pr comment 57 --body=\"@claude review 한국어로\""')"  '--body= 붙임표 형태'
r 0 "$(feed '"cd /somewhere && gh pr comment 57 --body \"@codex review\""')" '앞에 cd 가 붙어도 읽는다'

# 파일 형태는 **내용과 무관하게** 막는다. 훅은 실행 전에 도는데 같은 명령줄이
# 파일을 덮어쓴 뒤 보낼 수 있어, 훅이 본 것과 전송되는 것이 다르다(TOCTOU).
TMPB=$(mktemp -d)
printf '@codex review 한국어로\n' > "$TMPB/bot.txt"
printf '여기 버그가 있습니다\n'    > "$TMPB/review.txt"
r 2 "$(feed "\"gh pr comment 57 --body-file $TMPB/bot.txt\"")"     '파일 안이 봇 토큰이어도 막는다'
r 2 "$(feed "\"gh pr comment 57 --body-file $TMPB/review.txt\"")"  '파일 안이 리뷰 내용이면 막는다'
r 2 "$(feed "\"gh pr comment 57 -F $TMPB/bot.txt\"")"             '-F 짧은 형태도 막는다'

# codex 가 짚은 실제 우회 시나리오. 같은 명령줄이 먼저 덮어쓴다.
r 2 "$(feed "\"printf '사람 리뷰' > $TMPB/bot.txt; gh pr comment 57 --body-file $TMPB/bot.txt\"")" \
   '같은 줄에서 파일을 덮어써도 못 뚫는다'
rm -rf "$TMPB"

echo "── 우회 시도 (PR #58 봇 지적) ──"
# codex: 닫는 따옴표 뒤에 문자를 이으면 셸은 이어 붙이는데, 옛 판정은 닫는
# 따옴표 뒤를 버려서 통과시켰다.
r 2 "$(feed $'"gh pr comment 58 --body \'@codex review 한국어로\'그리고이건리뷰"')" \
   '인용 뒤에 문자를 이으면 막는다'

# claude: --body 를 두 번 쓰면 greedy 매치가 뒤쪽만 읽어, 실제 전송되는 앞쪽
# 사람 리뷰를 못 봤다.
r 2 "$(feed $'"gh pr comment 58 --body \\"이렇게 쓰면 된다: --body \'@codex review\'\\""')" \
   '--body 를 두 번 써도 못 뚫는다'

# 뒤에 다른 명령을 잇는 형태. 이제 명령줄 전체를 대조하므로 형태가 안 맞는다.
r 2 "$(feed $'"gh pr comment 58 --body \'@codex review\' && echo 끝"')" \
   '뒤에 다른 명령이 붙으면 막는다'
r 2 "$(feed $'"echo 시작; gh pr comment 58 --body \'@codex review\'"')" \
   '앞에 다른 명령이 붙으면 막는다'

# 여는 것과 닫는 것이 다른 인용.
r 2 "$(feed $'"gh pr comment 58 --body \'@codex review\\""')" \
   '인용이 어긋나면 막는다'

# cd 자리에 명령을 숨기는 것.
r 2 "$(feed $'"cd $(echo /tmp) && gh pr comment 58 --body \'@codex review\'"')" \
   'cd 경로에 치환을 숨기면 막는다'

# 통과해야 할 것이 여전히 통과하는지. 좁히면 거짓 차단이 늘어난다.
r 0 "$(feed $'"gh pr comment 58 --body \'@claude review 한국어로\'"')" \
   '봇 호출은 그대로 통과한다'
r 0 "$(feed $'"gh pr comment 58 -b \\"@codex review\\""')" \
   '-b 짧은 형태도 통과한다'

echo "── 우회 시도 (PR #61 봇 지적) ──"
# 탭을 공백으로 바꿔서 재면 `@codex<탭>review` 가 통과하는데, 셸과 gh 는 탭이
# 든 본문을 그대로 보낸다 — 훅이 본 것과 전송되는 것이 갈린다.
r 2 "$(feed $'"gh pr comment 61 --body \'@codex\\treview\'"')" \
   '본문에 탭이 있으면 막는다'
r 2 "$(feed $'"gh pr comment 61 --body \'@codex\\nreview\'"')" \
   '본문에 개행이 있으면 막는다'
r 0 "$(feed $'"gh pr comment 61 --body \'@codex review\'"')" \
   '공백 하나인 정상 토큰은 통과한다'

echo "── 우회 시도 (PR #62 봇 지적) ──"
# `[[:space:]]*$` 가 \r 을 공백으로 받아 주는데, gh 는 본문에 담아 보낸다.
r 2 "$(feed $'"gh pr comment 62 --body \'@codex review\'\\r"')" \
   '끝에 캐리지 리턴이 붙으면 막는다'
r 2 "$(feed $'"gh pr comment 62 --body \'@codex\\rreview\'"')" \
   '본문 안의 캐리지 리턴도 막는다'

echo "── 우회 시도 (PR #71 봇 지적) ──"
# 낱말 사이에 탭·이중 공백을 넣으면 디스패처가 못 알아봤다. 셸에서는 정상 호출이다.
r 2 "$(feed '"gh\tpr\tcomment 71 --body 사람리뷰"')" \
   '탭으로 구분한 코멘트 명령도 막는다'
r 2 "$(feed $'"gh  pr  comment 71 --body \'사람 리뷰\'"')" \
   '공백 두 개로 구분해도 막는다'
r 2 "$(feed '"gh\tpr\treview 71 --approve"')" \
   '탭으로 구분한 리뷰 명령도 막는다'

# gh api 의 필드 플래그를 전부 잡는다. 하나라도 붙으면 gh 는 POST 로 바꾼다.
r 2 "$(feed $'"gh api repos/o/r/issues/1/comments -F body=x"')" \
   '-F 로 만드는 코멘트를 막는다'
r 2 "$(feed $'"gh api repos/o/r/issues/1/comments --raw-field body=x"')" \
   '--raw-field 도 막는다'
r 2 "$(feed $'"gh api repos/o/r/pulls/1/reviews -fbody=x"')" \
   '붙여 쓴 -fbody= 도 막는다'

# 조회(GET)는 여전히 통과해야 한다 — 봇 리뷰를 읽어야 한다.
r 0 "$(feed $'"gh api repos/o/r/pulls/1/reviews --paginate"')" \
   '리뷰 조회는 통과한다'
r 0 "$(feed $'"gh api --hostname github.com repos/o/r/issues/1/comments"')" \
   '코멘트 조회도 통과한다'

echo "── 거짓 차단 (PR #72 봇 지적) ──"
# jq 식 안의 문자열에 ` -f` 가 들어가도 조회는 통과해야 한다.
r 0 "$(feed $'"gh api repos/o/r/issues/1/comments --jq \'.[] | select(.body == \\" -foo\\")\'"')" \
   'jq 식 안의 -foo 를 필드 플래그로 오인하지 않는다'
r 0 "$(feed $'"gh api repos/o/r/pulls/1/reviews -q \'.[] | .body\'"')" \
   '필터가 붙은 조회도 통과한다'
# 그래도 진짜 필드 플래그는 잡는다.
r 2 "$(feed $'"gh api repos/o/r/issues/1/comments -f body=x"')" \
   '소문자 단축형은 여전히 막는다'

echo "── 대상 형식 (PR #73 봇 지적) ──"
# gh 공식 사용법은 `<번호>|<URL>|<브랜치>` 셋 다 받는다. 숫자만 허용했더니
# URL 로 부르는 정상 봇 호출이 막혔다.
r 0 "$(feed $'"gh pr comment https://github.com/o/r/pull/57 --body \'@codex review 한국어로\'"')" \
   'URL 대상으로도 봇을 부를 수 있다'
r 0 "$(feed $'"gh pr comment feature/x --body \'@claude review\'"')" \
   '브랜치 이름 대상도 통과한다'
r 0 "$(feed $'"gh pr comment -R o/r 57 --body \'@codex review\'"')" \
   '-R 로 저장소를 짚어도 통과한다'
r 0 "$(feed $'"gh pr comment 57 --repo o/r --body \'@codex review\'"')" \
   '--repo 가 뒤에 와도 통과한다'

# 대상이 넓어졌다고 본문 검사가 헐거워지면 안 된다.
r 2 "$(feed $'"gh pr comment https://github.com/o/r/pull/57 --body \'사람 리뷰\'"')" \
   'URL 대상이어도 리뷰 내용은 막는다'
r 2 "$(feed $'"gh pr comment -R o/r 57 --body \'사람 리뷰\'"')" \
   '-R 이 붙어도 리뷰 내용은 막는다'
# 대상 자리에 명령을 숨길 수 없다.
r 2 "$(feed $'"gh pr comment $(echo 57) --body \'@codex review\'"')" \
   '대상 자리에 치환을 숨기면 막는다'

echo "── 거짓 차단 (PR #73 봇 지적) ──"
# jq 식 안의 `-foo=bar` 는 필드 플래그가 아니다.
r 0 "$(feed $'"gh api repos/o/r/issues/1/comments --jq \'.[] | select(.body == \\" -foo=bar\\")\'"')" \
   'jq 식 안의 -foo=bar 를 필드 플래그로 오인하지 않는다'
# 인용 밖의 진짜 플래그는 여전히 잡는다.
r 2 "$(feed $'"gh api repos/o/r/issues/1/comments -fbody=x"')" \
   '붙여 쓴 -fbody= 는 여전히 막는다'

echo
echo "════ 합계: OK $pass / FAIL $fail ════"
[ "$fail" -eq 0 ]
