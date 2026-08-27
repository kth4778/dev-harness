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

# ── 6. Phase N 의 「다음」이 Phase N+1 을 가리키나 ──────────────
# 5번은 **가리키는 스킬이 실재하나**만 봤다. 그래서 `pr` 의 다음을 `sync` 가 아니라
# `retro` 로 바꿔도 초록이었다 — 둘 다 실재하니까. 그러면 Phase 8 이 도달 불가인데
# 시험은 통과한다(codex, PR #108). 사슬은 **순서**가 본체라 그것을 직접 잰다.
wrong=0
for f in "$S"/*/SKILL.md; do
    # 🔴 grep -oE '[0-9]+$' 를 쓰지 마라. 매치가 ')' 로 끝나 숫자가 줄 끝이 아니고,
    #    그러면 n 이 빈 채 continue 로 빠져 **이 갈래 전체가 아무것도 안 잰다**
    #    (실측: 주입해도 초록. 「통과한다」와 「잰다」는 다르다).
    n=$(grep -m1 -E '^# .*\(Phase [0-9]+\)' "$f" | sed -E 's/.*\(Phase ([0-9]+)\).*/\1/')
    [ -n "$n" ] || continue
    [ "$n" = "$last" ] && continue          # 마지막 Phase 는 다음이 없다
    # 이 스킬이 tdd-java 처럼 Phase 를 공유하면 건너뛴다 — 사슬의 마디가 아니다.
    owner=$(grep -l "^# .*(Phase $n)" "$S"/*/SKILL.md | head -1)
    [ "$f" = "$owner" ] || continue
    nxt=$((n + 1))
    want=$(basename "$(dirname "$(grep -l "^# .*(Phase $nxt)" "$S"/*/SKILL.md | head -1)")")
    got=$(sed -n '/^## 다음/,$p' "$f" | grep -ohE '`[a-z-]+` 스킬' | tr -d '`' | sed 's/ 스킬//' | head -1)
    [ "$got" = "$want" ] || {
        wrong=$((wrong+1))
        echo "      Phase $n($(basename "$(dirname "$f")")) 의 다음이 '$got' 다 — Phase $nxt 는 '$want'"; }
done
r 0 "$wrong" "각 Phase 의 「다음」이 바로 다음 Phase 를 가리킨다"

# ── 7. 아무 스킬도 안 가리키는 references 파일이 있나 ────────────
# 스킬을 옮길 때 옛 자리의 참조 문서가 **지워지지 않고 남는다.** 이 판에서 실제로
# 그랬다 — git mv 로 옮긴 뒤 커밋에 삭제 쪽을 안 담아, 옛 문서가 살아남아
# 「retro 로 가라」는 **정반대**를 지시하고 있었다(claude·codex, PR #108).
orphan=0
for ref in "$S"/*/references/*.md; do
    [ -e "$ref" ] || continue
    name=$(basename "$ref")
    owner=$(dirname "$(dirname "$ref")")
    grep -rqF "references/$name" "$owner/SKILL.md" || {
        orphan=$((orphan+1))
        echo "      고아: ${ref#"$S/"} — 같은 스킬의 SKILL.md 가 안 가리킨다"; }
done
r 0 "$orphan" "references 문서를 그 스킬의 SKILL.md 가 전부 가리킨다"

printf '\n════ 합계: OK %s / FAIL %s ════\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
