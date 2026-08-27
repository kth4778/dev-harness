#!/usr/bin/env bash
# Phase 사슬이 끊기지 않았나를 잰다 — 스킬 문서만 읽는다. 훅도 커밋도 안 만든다.
#
# 왜 있나 (2026-08-27, Phase 8 `sync` 를 꺼내면서):
#
#   이 하네스가 잊는 것을 막는 방식은 **스킬이 다음 스킬을 명확히 가리키는 것**
#   하나뿐이다. 그런데 그 사슬 자체를 재는 것이 없었다 — 스킬 하나를 끼워 넣으면
#   Phase 번호가 아홉 자리에서 밀리는데, 한 자리만 고쳐도 시험은 그대로 초록이었다.
#   실제로 그 판에서 「10단계 스킬 몇 개」를 손으로 세다 **두 번 연속 틀렸고**,
#   원래 값(「8단계 10개」)도 review-loop 을 넣을 때 안 고쳐져 이미 낡아 있었다.
#
#   그래서 사람이 세지 않게 한다. 숫자는 코드가 센다.
ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
S="$ROOT/skills"
if [ ! -d "$S" ]; then
    echo "  [SKIP] $S 가 없다 — 훅만 담긴 옛 트리로 보인다"
    exit 0
fi

pass=0; fail=0
r() { if [ "$1" = "$2" ]; then pass=$((pass+1)); printf '  [OK ] '; else fail=$((fail+1)); printf '  [FAIL] '; fi
     printf '기대 %s / 실제 %s  %s\n' "$1" "$2" "$3"; }

# ── 1. Phase 번호가 1부터 빠짐없이 이어지나 ──────────────────
# 사슬에 구멍이 나는 것이 정확히 「한 자리만 고쳤다」의 증상이다.
nums=$(grep -h '^# .*(Phase [0-9]*)' "$S"/*/SKILL.md \
       | sed -E 's/.*\(Phase ([0-9]+)\).*/\1/' | sort -n -u)
last=$(printf '%s\n' "$nums" | tail -1)
expected=$(seq 1 "$last")
r "$(printf '%s' "$expected" | tr -d ' \n')" "$(printf '%s' "$nums" | tr -d ' \n')" \
  "Phase 번호가 1..$last 로 빠짐없이 이어진다"

# ── 2. bootstrap 의 워크플로 표가 실제 Phase 수와 같나 ──────────
# 표는 사람이 손으로 고치는 자리라 스킬을 넣고도 안 고치기 쉽다.
rows=$(grep -cE '^\| [0-9]+ \| ' "$S/bootstrap/SKILL.md")
r "$last" "$rows" "bootstrap 워크플로 표의 행 수가 Phase 수와 같다"

# ── 3. 「N단계」라고 쓴 숫자가 실제와 같나 ───────────────────────
# 원래 값이 낡아 있던 자리가 정확히 여기다.
declared=$(grep -ohE '[0-9]+단계를 순서대로' "$S/bootstrap/SKILL.md" | head -1 | tr -dc '0-9')
r "$last" "${declared:-없음}" "bootstrap 이 말하는 단계 수가 실제와 같다"

# ── 4. 각 스킬의 「다음」이 실재하는 스킬을 가리키나 ─────────────
# 끊긴 링크는 사슬이 거기서 멈춘다는 뜻이다.
missing=0
for f in "$S"/*/SKILL.md; do
    nxt=$(sed -n '/^## 다음/,$p' "$f" | grep -ohE '`[a-z-]+` 스킬' | tr -d '`' | sed 's/ 스킬//' | sort -u)
    for n in $nxt; do
        [ -d "$S/$n" ] || { missing=$((missing+1)); echo "      끊김: $(basename "$(dirname "$f")") → $n"; }
    done
done
r 0 "$missing" "「다음」이 가리키는 스킬이 전부 실재한다"

# ── 5. Phase 를 가진 스킬은 description 에도 앞뒤가 적혀 있나 ────
# 스킬 목록만 보고 부르는 자리가 있어서, description 이 사슬의 유일한 안내인 때가 있다.
noref=0
for f in "$S"/*/SKILL.md; do
    grep -q '^# .*(Phase [0-9]*)' "$f" || continue
    grep -m1 '^description:' "$f" | grep -q '스킬의' || {
        noref=$((noref+1)); echo "      앞 단계 표기 없음: $(basename "$(dirname "$f")")"; }
done
# spec 은 첫 Phase 라 앞 단계가 없다. tdd-java 는 build 안에서 불린다.
r 2 "$noref" "앞 단계를 안 적은 스킬은 둘뿐이다 (spec · tdd-java)"

printf '\n════ 합계: OK %s / FAIL %s ════\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
