#!/usr/bin/env bash
# skills/inspect/scripts/check-branch-commits.sh 의 갈래를 잰다.
ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
SCRIPT="$ROOT/skills/inspect/scripts/check-branch-commits.sh"
if [ ! -f "$SCRIPT" ]; then
    echo "  [SKIP] $SCRIPT 가 없다 — 훅만 담긴 옛 트리로 보인다"
    exit 0
fi
R=$(mktemp -d); BIN=$(mktemp -d)
trap 'rm -rf "$R" "$BIN"' EXIT

pass=0; fail=0
r() { if [ "$1" = "$2" ]; then pass=$((pass+1)); printf '  [OK ] '; else fail=$((fail+1)); printf '  [FAIL] '; fi
     printf '기대 %s / 실제 %s  %s\n' "$1" "$2" "$3"; }

# gh 는 없는 것으로 둔다(재사용 검사는 건너뛴다). 필요할 때만 가짜를 놓는다.
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  *"repo view"*) printf '%s\n' "${GH_UPSTREAM:-}" ;;
  *"pr list"*)   printf '%s\n' "${GH_PRIOR:-}" ;;
esac
GH
chmod +x "$BIN/gh"; export PATH="$BIN:$PATH"

fresh() {
    rm -rf "$R"; mkdir -p "$R/remote" "$R/work"
    git init -q --bare -b main "$R/remote"
    git clone -q "$R/remote" "$R/work" 2>/dev/null
    cd "$R/work" || exit 1
    git config user.email t@t.t; git config user.name t
    printf 'base\n' > base.txt; git add base.txt; git commit -qm init
    git push -q origin main 2>/dev/null; git remote set-head origin main 2>/dev/null
}
out_of() { bash "$SCRIPT" "${1:-main}" 2>&1; }

echo "── 보호 브랜치 ──"
fresh; printf 'x\n' > f.txt; git add f.txt
r 1 "$(out_of >/dev/null 2>&1; echo $?)" 'main 에서 돌리면 FAIL'
printf '%s' "$(out_of)" | grep -q "보호 브랜치" && r y y '이유를 알린다' || r y n '이유를 알린다'

echo "── 비ASCII 이름 ──"
fresh; git switch -qc "feature/한글"
printf 'x\n' > f.txt; git add f.txt; git commit -qm work
r 1 "$(out_of >/dev/null 2>&1; echo $?)" '한글 브랜치는 FAIL'

echo "── 정상 브랜치 ──"
fresh; git switch -qc feature/ok
printf 'x\n' > f.txt; printf 'y\n' > f_test.txt; git add .; git commit -qm "feat: 뭔가 한다"
r 0 "$(out_of >/dev/null 2>&1; echo $?)" '구현+테스트가 든 커밋은 PASS'
printf '%s' "$(out_of)" | grep -q "커밋 1개" && r y y '커밋 수를 센다' || r y n '커밋 수를 센다'

echo "── BASE 가 실제로 계산된다 ──"
fresh; git switch -qc feature/three
for i in 1 2 3; do printf '%s\n' "$i" > "f$i.txt"; printf 't\n' > "f${i}_test.txt"; git add .; git commit -qm "feat: $i"; done
printf '%s' "$(out_of)" | grep -q "커밋 3개" && r y y '3개를 3개로 센다(HEAD..HEAD 로 죽지 않는다)' || r y n '3개를 3개로 센다'

echo "── 갈라진 커밋을 짚는다 ──"
fresh; git switch -qc feature/split
printf 'x\n' > src.txt; git add src.txt; git commit -qm "feat: 구현만"
printf 't\n' > src_test.txt; git add src_test.txt; git commit -qm "test: 검사만"
o=$(out_of); printf '%s' "$o" | grep -q "갈라진 커밋" && r y y '구현만·테스트만 있는 커밋을 짚는다' || r y n '구현만·테스트만 있는 커밋을 짚는다'
printf '%s' "$o" | grep -q "구현만" && r y y '어느 커밋인지 알린다' || r y n '어느 커밋인지 알린다'

echo "── 리팩터·문서는 예외 ──"
fresh; git switch -qc feature/refactor
printf 'x\n' > src.txt; git add src.txt; git commit -qm "refactor: 옮긴다"
printf 'd\n' > README.md; git add README.md; git commit -qm "docs: 적는다"
printf '%s' "$(out_of)" | grep -q "갈라진 커밋" && r n y '리팩터·문서는 안 짚는다' || r n n '리팩터·문서는 안 짚는다'

echo "── 같은 파일 반복 ──"
fresh; git switch -qc feature/repeat
for i in 1 2 3; do printf '%s\n' "$i" > same.txt; printf 't\n' > same_test.txt; git add .; git commit -qm "feat: $i"; done
printf '%s' "$(out_of)" | grep -q "3회  same.txt" && r y y '세 번 건드린 파일을 짚는다' || r y n '세 번 건드린 파일을 짚는다'

echo "── 옛 PR 이 있으면 ──"
fresh; git switch -qc feature/prior
printf 'x\n' > f.txt; printf 't\n' > f_test.txt; git add .; git commit -qm "feat: x"
r 1 "$(GH_UPSTREAM=o/r GH_PRIOR='{"number":9,"state":"MERGED"}' out_of >/dev/null 2>&1; echo $?)" '옛 PR 이 있으면 FAIL'

echo
echo "════ 합계: OK $pass / FAIL $fail ════"
[ "$fail" -eq 0 ]
