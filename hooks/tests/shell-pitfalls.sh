#!/usr/bin/env bash
# check-shell-pitfalls.sh 시험 — 결함을 주입해 빨간불부터 확인한다(승격 규칙:
# 「그 결함에서 실패한 적 없는 시험은 시험이 아니다」).
set -uo pipefail

# run-all 이 넘기는 대체 훅 폴더를 받는다 — 다른 시험들과 같은 규약이다.
# 무시하면 「고치기 전후 비교」가 이 시험에서만 늘 현재 체크아웃을 잰다.
H="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$H/../skills/inspect/scripts/check-shell-pitfalls.py"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
r() {
    local mark="OK "
    if [ "$1" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); mark="FAIL"; fi
    printf '  [%s] 기대 %s / 실제 %s  %s\n' "$mark" "$1" "$2" "$3"
}

echo "── 결함 주입 — 빨간불 먼저 ──"
mkdir -p "$T/a"
printf '#!/usr/bin/env bash\nset -o pipefail\nfoo | grep -q bar || exit 1\n' > "$T/a/bad.sh"
r 1 "$(python3 "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" '파이프 뒤 grep -q 를 잡는다'

printf '#!/usr/bin/env bash\ncmd | grep -Eq "pat" && x=1\n' > "$T/a/bad.sh"
r 1 "$(python3 "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" '결합 플래그(-Eq)도 잡는다'

# 파이프가 앞 줄에 있고 grep 이 줄머리에 오는 여러 줄 파이프라인.
# 도입 직후 실제 운영 코드에서 이 형태 2건을 찾았다 — 한 줄 grep 은 놓친다.
printf '#!/usr/bin/env bash\nprintf x \\\\\n    | grep -Eq "pat" \\\\\n    || exit 0\n' > "$T/a/bad.sh"
r 1 "$(python3 "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" '여러 줄 파이프라인의 grep -q 도 잡는다'

echo "── 통과해야 할 것 ──"
printf '#!/usr/bin/env bash\n# 주석: grep -q 를 쓰면 안 된다\nn=$(cmd | grep -c pat || true)\n' > "$T/a/bad.sh"
r 0 "$(python3 "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" '주석과 grep -c 는 통과한다'

printf '#!/usr/bin/env bash\ngrep -q pat file.txt || exit 0\n' > "$T/a/bad.sh"
r 0 "$(python3 "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" '파이프 없는 grep -q(파일 인자)는 통과한다'

mkdir -p "$T/a/tests"
printf 'x | grep -q y\n' > "$T/a/tests/fixture.sh"
rm -f "$T/a/bad.sh"
r 0 "$(python3 "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" 'tests/ 폴더는 검사하지 않는다'

echo "── PR #86 지적 — 놓치던 세 형태 ──"
printf '#!/usr/bin/env bash\ncmd | grep -qE pat || exit 1\n' > "$T/a/bad.sh"
r 1 "$(python3 "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" 'q 가 앞에 오는 결합(-qE)도 잡는다'

printf '#!/usr/bin/env bash\ncmd | grep --quiet pat && x=1\n' > "$T/a/bad.sh"
r 1 "$(python3 "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" '--quiet 긴 이름도 잡는다'

printf '#!/usr/bin/env bash\ncmd | \\\n    grep -Eq pat || exit 0\n' > "$T/a/bad.sh"
r 1 "$(python3 "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" '백슬래시 연속 뒤의 grep -q 도 잡는다'

printf '#!/usr/bin/env bash\ncmd |\n    grep -q pat || exit 0\n' > "$T/a/bad.sh"
r 1 "$(python3 "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" '줄 끝 파이프(trailing) 뒤도 잡는다'

# 결합이 오탐을 만들면 안 된다 — 여러 줄 grep -c 는 정당하다.
printf '#!/usr/bin/env bash\nn=$(cmd | \\\n    grep -c pat || true)\n' > "$T/a/bad.sh"
r 0 "$(python3 "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" '여러 줄 grep -c 는 통과한다'

echo "── PR #87 지적 ──"
# quiet 가 다른 옵션 뒤에 와도 잡는다.
printf '#!/usr/bin/env bash\ncmd | grep -E --quiet pat || exit 1\n' > "$T/a/bad.sh"
r 1 "$(python3 "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" '-E --quiet 순서도 잡는다'

# 인용된 예시 문자열은 실행 코드가 아니다 — 거짓 차단이 났던 형태.
printf "#!/usr/bin/env bash\nprintf '%%s' 'example: cmd | grep -q pat'\n" > "$T/a/bad.sh"
r 0 "$(python3 "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" '인용된 예시는 오인하지 않는다'

# 인용을 지워도 진짜 함정은 남는다 — 패턴 인자가 인용돼 있어도 잡는다.
printf '#!/usr/bin/env bash\ncmd | grep -q "pat" || exit 1\n' > "$T/a/bad.sh"
r 1 "$(python3 "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" '패턴이 인용돼 있어도 잡는다'

echo "── PR #89 지적 ──"
# ${dir#./} 의 # 가 주석으로 읽히면 그 뒤 파이프가 사라진 채 통과한다.
printf '#!/usr/bin/env bash\ncat ${dir#./}/f | grep -q needle || exit 1\n' > "$T/a/bad.sh"
r 1 "$(python3 "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" '파라미터 확장의 # 뒤 파이프도 잡는다'
rm -f "$T/a/bad.sh"

echo "── PR #90 지적 ──"
# 인접 구두점(`)|`)이 파이프를 삼키면 거짓 통과다.
printf '#!/usr/bin/env bash\n$(cmd)|grep -q pat || exit 1\n' > "$T/a/bad.sh"
r 1 "$(python3 "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" '공백 없는 )|grep -q 도 잡는다'

# 줄 끝 진짜 주석 속 -q 언급은 오탐이 아니어야 한다.
printf '#!/usr/bin/env bash\nn=$(cmd | grep -c pat)   # -q 를 쓰면 안 된다\n' > "$T/a/bad.sh"
r 0 "$(python3 "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" '주석 속 -q 언급을 오판하지 않는다'
rm -f "$T/a/bad.sh"

echo "── PR #91 지적 ──"
# 인용된 '#' 인자를 주석으로 오인하면 그 뒤 파이프가 거짓 통과한다.
printf "#!/usr/bin/env bash\nprintf '%%s' '# value' | grep -q value || exit 1\n" > "$T/a/bad.sh"
r 1 "$(python3 "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" "인용된 '#' 인자 뒤의 파이프도 잡는다"
rm -f "$T/a/bad.sh"

echo "── PR #93 지적 ──"
# 단어 중간에서 시작하는 인용 — shlex(posix=False)는 인용 진입을 토큰 시작에서만
# 인식해, 대입문 값 속의 파이프가 실 토큰으로 나와 정상 스크립트를 거짓 차단했다.
printf '#!/usr/bin/env bash\nMSG="do not: cmd | grep -q pat"\nprintf %%s "$MSG"\n' > "$T/a/bad.sh"
r 0 "$(python3 "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" '단어 중간 인용(VAR="…") 예시를 오인하지 않는다'

printf "#!/usr/bin/env bash\nlog --msg='never: cmd | grep -q pat'\n" > "$T/a/bad.sh"
r 0 "$(python3 "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" "단어 중간 인용(--msg='…')도 오인하지 않는다"

# 차단 갈래도 함께 잰다(승격 규칙 ⑤) — 인용 밖의 진짜 파이프는 여전히 잡는다.
printf '#!/usr/bin/env bash\necho "x" | grep -q x || exit 1\n' > "$T/a/bad.sh"
r 1 "$(python3 "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" '인용 인자가 있어도 인용 밖 파이프는 잡는다'
rm -f "$T/a/bad.sh"

# 자기 제외가 접두사 매칭이면 이름을 흉내 낸 운영 스크립트가 검사를 빠져나간다.
printf '#!/usr/bin/env bash\ncmd | grep -q pat\n' > "$T/a/check-shell-pitfalls.legacy.sh"
r 1 "$(python3 "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" '자기 이름을 흉내 낸 파일은 빼지 않는다'
rm -f "$T/a/check-shell-pitfalls.legacy.sh"

# CP949 콘솔 대비 — 쌍둥이 두 파일에는 있는데 이 파일에만 빠져 PASS 출력의
# U+2014 에서 죽었다. 형태로 잰다(출력 인코딩은 환경 의존이라 재현이 안 된다).
n=$(grep -c 'reconfigure' "$SCRIPT" || true)
r 1 "$([ "$n" -ge 1 ] && echo 1 || echo 0)" 'CP949 대비 스트림 reconfigure 가 있다'

echo "── PR #94 지적 ──"
# 큰따옴표 안 명령 치환의 파이프는 셸이 실제로 실행하는 진짜 파이프다 —
# 인용 리터럴로 삼키면 거짓 통과다(직전 커밋의 스캐너 교체가 만든 회귀).
printf '#!/usr/bin/env bash\nout="found: $(cmd | grep -q pat && echo y)"\n' > "$T/a/bad.sh"
r 1 "$(python3 "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" '큰따옴표 안 $(… | grep -q …) 를 잡는다'

# 통과 쌍(승격 규칙 ⑤) — 작은따옴표 안 $() 는 셸에서도 리터럴이다.
printf "#!/usr/bin/env bash\nmsg='ex: \$(cmd | grep -q pat)'\nprintf %%s \"\$msg\"\n" > "$T/a/bad.sh"
r 0 "$(python3 "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" "작은따옴표 안 \$() 는 리터럴 — 오인하지 않는다"
rm -f "$T/a/bad.sh"

echo "── 실제 저장소 ──"
# 출력을 버리지 않는다 — CI 에서 실패했을 때 어느 파일이 걸렸는지 로그에
# 안 남아 진단이 안 됐다(2026-08-14 실물). 실패하면 그대로 보여준다.
repo_out=$(python3 "$SCRIPT" 2>&1); repo_rc=$?
[ "$repo_rc" -eq 0 ] || printf '%s\n' "$repo_out" >&2
r 0 "$repo_rc" '운영 스크립트 전체가 깨끗하다'

echo
echo "════ 합계: OK $pass / FAIL $fail ════"
[ "$fail" -eq 0 ]
