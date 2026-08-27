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

# all(디스패처)도 목록에 넣는다. 빼 두면 그 결과가 총계에 안 잡혀
# 디스패처가 깨져도 suite 가 통과한다 (codex, PR #24).
total_ok=0; total_fail=0
for t in guards codex mode p2 pr-guard cleanup inspect-checks shell-pitfalls panel-tally phase-chain all; do
    printf '\n════════ %s ════════\n' "$t"
    # cleanup 만 저장소 루트를 받는다 — 훅이 아니라 skills/ 의 스크립트를 잰다
    if [ "$t" = cleanup ] || [ "$t" = inspect-checks ] || [ "$t" = panel-tally ] \
   || [ "$t" = phase-chain ]; then arg=$(cd "$H/.." && pwd); else arg="$H"; fi
    out=$(bash "$here/$t.sh" "$arg" 2>&1); st=$?
    printf '%s\n' "$out"
    ok=$(printf '%s' "$out"   | grep -c '\[OK ')
    bad=$(printf '%s' "$out"  | grep -c '\[FAIL')
    total_ok=$((total_ok + ok)); total_fail=$((total_fail + bad))
    # 마커 없이 죽은 경우 — 문법 오류, source 실패, 이른 exit. 마커만 세면
    # 이런 크래시가 "FAIL 0"으로 보여 suite 가 거짓 초록이 된다 (codex, PR #25).
    if [ "$st" -ne 0 ] && [ "$bad" -eq 0 ]; then
        printf '  [FAIL] %s.sh 가 마커 없이 exit %s 로 죽었다\n' "$t" "$st"
        total_fail=$((total_fail + 1))
    fi
done

printf '\n════════ 총계: OK %s / FAIL %s ════════\n' "$total_ok" "$total_fail"
[ "$total_fail" -eq 0 ]
