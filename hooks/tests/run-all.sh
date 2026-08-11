#!/usr/bin/env bash
# 훅 시험 전부. 훅을 고쳤으면 고치기 전과 고친 뒤 이것을 돌리고 숫자를 비교한다.
#
#   hooks/tests/run-all.sh              # 이 저장소의 훅
#   hooks/tests/run-all.sh <훅폴더>     # 다른 판본(예: git show 로 꺼낸 옛 버전)
#
# 세 갈래를 다 담는다 — 막아야 할 것 · 통과해야 할 것 · 판정 근거가 없을 때.
# 자세한 것은 RULES.md 「훅을 고칠 때」 절에 있다.
#
# 버릴 저장소를 매번 새로 만들어 훅 스크립트에 입력을 직접 먹인다.
# 진짜 커밋은 하나도 만들지 않는다.
here=$(cd "$(dirname "$0")" && pwd)
H="${1:-$(cd "$here/.." && pwd)}"

total_ok=0; total_fail=0
for t in guards codex mode p2 pr-guard; do
    printf '\n════════ %s ════════\n' "$t"
    out=$(bash "$here/$t.sh" "$H" 2>&1)
    printf '%s\n' "$out"
    ok=$(printf '%s' "$out"   | grep -c '\[OK ')
    bad=$(printf '%s' "$out"  | grep -c '\[FAIL')
    total_ok=$((total_ok + ok)); total_fail=$((total_fail + bad))
done

printf '\n════════ 디스패처 경유 ════════\n'
bash "$here/all.sh" "$H"

printf '\n════════ 총계: OK %s / FAIL %s ════════\n' "$total_ok" "$total_fail"
[ "$total_fail" -eq 0 ]
