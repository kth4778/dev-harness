#!/usr/bin/env bash
# check-shell-pitfalls.sh 시험 — 결함을 주입해 빨간불부터 확인한다(승격 규칙:
# 「그 결함에서 실패한 적 없는 시험은 시험이 아니다」).
set -uo pipefail

H="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$H/../skills/inspect/scripts/check-shell-pitfalls.sh"
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
r 1 "$(bash "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" '파이프 뒤 grep -q 를 잡는다'

printf '#!/usr/bin/env bash\ncmd | grep -Eq "pat" && x=1\n' > "$T/a/bad.sh"
r 1 "$(bash "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" '결합 플래그(-Eq)도 잡는다'

# 파이프가 앞 줄에 있고 grep 이 줄머리에 오는 여러 줄 파이프라인.
# 도입 직후 실제 운영 코드에서 이 형태 2건을 찾았다 — 한 줄 grep 은 놓친다.
printf '#!/usr/bin/env bash\nprintf x \\\\\n    | grep -Eq "pat" \\\\\n    || exit 0\n' > "$T/a/bad.sh"
r 1 "$(bash "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" '여러 줄 파이프라인의 grep -q 도 잡는다'

echo "── 통과해야 할 것 ──"
printf '#!/usr/bin/env bash\n# 주석: grep -q 를 쓰면 안 된다\nn=$(cmd | grep -c pat || true)\n' > "$T/a/bad.sh"
r 0 "$(bash "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" '주석과 grep -c 는 통과한다'

printf '#!/usr/bin/env bash\ngrep -q pat file.txt || exit 0\n' > "$T/a/bad.sh"
r 0 "$(bash "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" '파이프 없는 grep -q(파일 인자)는 통과한다'

mkdir -p "$T/a/tests"
printf 'x | grep -q y\n' > "$T/a/tests/fixture.sh"
rm -f "$T/a/bad.sh"
r 0 "$(bash "$SCRIPT" "$T/a" >/dev/null 2>&1; echo $?)" 'tests/ 폴더는 검사하지 않는다'

echo "── 실제 저장소 ──"
r 0 "$(bash "$SCRIPT" >/dev/null 2>&1; echo $?)" '운영 스크립트 전체가 깨끗하다'

echo
echo "════ 합계: OK $pass / FAIL $fail ════"
[ "$fail" -eq 0 ]
