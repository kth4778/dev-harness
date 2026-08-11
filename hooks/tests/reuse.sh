#!/usr/bin/env bash
# 머지된 브랜치를 재사용하는 커밋을 막는지 본다.
#
# 2026-08-11에 실물로 겪었다. PR #18 이 머지된 뒤 그 브랜치를 그대로 두고
# 새 커밋을 얹었더니, PR 없이 원격에만 떠 있는 커밋이 됐다.
H="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
R=$(mktemp -d)
trap 'rm -rf "$R"' EXIT

pass=0; fail=0
r() { if [ "$1" = "$2" ]; then pass=$((pass+1)); printf '  [OK ] '; else fail=$((fail+1)); printf '  [FAIL] '; fi
     printf '기대 %s / 실제 %s  %s\n' "$1" "$2" "$3"; }
cg() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$1" | bash "$H/commit-guard" >/dev/null 2>&1; echo "$?"; }

# origin 이 있는 저장소를 만든다. 원격 없이는 「머지됐다」를 판정할 수 없다.
fresh() {
    rm -rf "$R"; mkdir -p "$R/remote" "$R/work"
    git init -q --bare -b main "$R/remote"
    git clone -q "$R/remote" "$R/work" 2>/dev/null
    cd "$R/work" || exit 1
    git config user.email t@t.t; git config user.name t; git config core.fileMode false
    printf 'base\n' > base.txt; git add base.txt; git commit -qm init
    git push -q origin main 2>/dev/null
    git remote set-head origin main 2>/dev/null
}

echo "── 막아야 할 것 ──"
fresh
git switch -qc feature/done
printf 'x\n' > f.txt; git add f.txt; git commit -qm work
git push -q origin feature/done 2>/dev/null
git switch -q main; git merge -q --no-ff feature/done -m "merge"; git push -q origin main 2>/dev/null
git switch -q feature/done                       # 머지된 브랜치로 되돌아옴
printf 'y\n' > g.txt; git add g.txt
r 2 "$(cg '"git commit -m more"')"               '머지된 브랜치에 새 커밋'

echo "── 통과해야 할 것 ──"
fresh
git switch -qc feature/fresh                     # 원격에 없는 새 브랜치
printf 'x\n' > f.txt; git add f.txt
r 0 "$(cg '"git commit -m work"')"               '방금 만든 브랜치 (원격에 없다)'

fresh
git switch -qc feature/inflight
printf 'x\n' > f.txt; git add f.txt; git commit -qm work
git push -q origin feature/inflight 2>/dev/null  # 올렸지만 아직 안 머지됨
printf 'y\n' > g.txt; git add g.txt
r 0 "$(cg '"git commit -m more"')"               '올렸지만 아직 안 머지된 브랜치'

fresh
git switch -qc feature/done2
printf 'x\n' > f.txt; git add f.txt; git commit -qm work
git push -q origin feature/done2 2>/dev/null
git switch -q main; git merge -q --no-ff feature/done2 -m "merge"; git push -q origin main 2>/dev/null
git switch -qc feature/next origin/main          # 머지 뒤 새로 판 브랜치
printf 'z\n' > h.txt; git add h.txt
r 0 "$(cg '"git commit -m next"')"               '머지 뒤 새로 판 브랜치'

# 원격이 없으면 판정할 근거가 없다. 근거 없이 막지 않는다 —
# 이 갈래는 되돌릴 수 있는 실수라 거짓 차단 쪽이 더 비싸다.
rm -rf "$R"; mkdir -p "$R"; cd "$R" || exit 1
git init -q -b feature/x .; git config user.email t@t.t; git config user.name t
printf 'base\n' > base.txt; git add base.txt; git commit -qm init
printf 'x\n' > f.txt; git add f.txt
r 0 "$(cg '"git commit -m work"')"               '원격이 없는 저장소'

echo "── codex 지적 (PR #34) ──"
# P2: 커밋 전에 push 한 브랜치는 tip 이 통합 브랜치와 **같다.** 도달 가능하다는
# 것이 머지됐다는 뜻은 아니다 — 머지된 브랜치의 tip 은 통합 브랜치와 다르다.
fresh
git switch -qc feature/published origin/main
git push -q -u origin feature/published 2>/dev/null   # 커밋 없이 먼저 올림
printf 'x\n' > f.txt; git add f.txt
r 0 "$(cg '"git commit -m first"')"              'P2 커밋 전에 push 한 브랜치'

# P1: 머지가 다른 곳(GitHub·다른 클론)에서 일어나고 아직 fetch 하지 않았다.
# origin/main 이 옛 커밋을 가리켜 판정이 빗나간다 — 막아야 할 바로 그 첫 커밋이다.
fresh
git switch -qc feature/remote-merged
printf 'x\n' > f.txt; git add f.txt; git commit -qm work
git push -q origin feature/remote-merged 2>/dev/null
git clone -q "$R/remote" "$R/other" 2>/dev/null       # 다른 클론이 머지한다
(cd "$R/other" && git config user.email t@t.t && git config user.name t \
   && git switch -q main && git merge -q --no-ff origin/feature/remote-merged -m merge \
   && git push -q origin main) 2>/dev/null
r 2 "$(cg '"git commit -m more"')"               'P1 원격에서 머지됐고 아직 fetch 안 함'

echo
echo "════ 합계: OK $pass / FAIL $fail ════"
[ "$fail" -eq 0 ]
