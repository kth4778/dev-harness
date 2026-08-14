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
# 가짜 gh 를 함수로 둔다. 한 갈래가 이것을 망가진 판으로 덮으면 **뒤 갈래가
# 그대로 물려받아** 엉뚱한 곳에서 실패한다 — 실제로 그렇게 됐다.
put_gh() {
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  # 세 칸 TSV: parent(있으면 fork) · 이 저장소 · URL.
  # GH_PARENT 를 주면 fork 상황이 된다.
  *"repo view"*)             printf '%s\t%s\t%s\n' \
                               "${GH_PARENT:-}" "${GH_UPSTREAM:-}" "${GH_URL:-}" ;;
  *"pr list"*"--state open"*) printf '%s\n' "${GH_CUR:-}" ;;
  # **`-q` 필터를 실제로 적용한다.** 그냥 뱉으면 스크립트의 jq 식이 시험에서
  # 한 번도 안 돌아, 필터가 틀려도 통과한다 (claude, PR #68 을 고치다 발견).
  # GH_PRIOR 는 객체 하나로 주고, 여기서 배열로 감싼다.
  *"pr list"*)
    q=; nx=0
    for a in "$@"; do
      [ "$nx" = 1 ] && { q="$a"; nx=0; continue; }
      [ "$a" = "-q" ] || [ "$a" = "--jq" ] && nx=1
    done
    if [ -n "${GH_PRIOR:-}" ] && [ -n "$q" ] && command -v jq >/dev/null 2>&1; then
      printf '[%s]' "$GH_PRIOR" | jq -r "$q" 2>/dev/null
    else
      printf '%s\n' "${GH_PRIOR:-}"
    fi ;;
esac
GH
chmod +x "$BIN/gh"
}
put_gh; export PATH="$BIN:$PATH"

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

# 옛 PR 응답을 만든다. 가짜 gh 가 `-q` 필터를 실제로 돌리므로 소유자가 맞아야
# 걸린다 — 현재 원격의 소유자를 그대로 넣는다.
prior() {
    printf '{"number":%s,"state":"%s","headRepositoryOwner":{"login":"%s"}}' \
      "$1" "$2" "$(basename "$(dirname "$(git remote get-url --push origin 2>/dev/null)")")"
}

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
o=$(out_of); rc_split=$(out_of >/dev/null 2>&1; echo $?)
printf '%s' "$o" | grep -q "갈라진 커밋" && r y y '구현만·테스트만 있는 커밋을 짚는다' || r y n '구현만·테스트만 있는 커밋을 짚는다'
printf '%s' "$o" | grep -q "구현만" && r y y '어느 커밋인지 알린다' || r y n '어느 커밋인지 알린다'
r 1 "$rc_split" '**찍기만 하지 않고 FAIL 로 끝난다**'

echo "── 예외는 경로로만 준다 ──"
# 문서만 바뀐 커밋은 예외다.
fresh; git switch -qc feature/docsonly
printf 'd\n' > README.md; git add README.md; git commit -qm "docs: 적는다"
printf '%s' "$(out_of)" | grep -q "갈라진 커밋" && r n y '문서만 바뀐 커밋은 안 짚는다' || r n n '문서만 바뀐 커밋은 안 짚는다'

# **제목으로는 예외를 주지 않는다.** refactor:·chore: 를 달아도 구현만 있으면 짚는다.
fresh; git switch -qc feature/refactortitle
printf 'x\n' > src.txt; git add src.txt; git commit -qm "refactor: 옮긴다"
printf '%s' "$(out_of)" | grep -q "갈라진 커밋" && r y y 'refactor: 제목으로 안 넘어간다' || r y n 'refactor: 제목으로 안 넘어간다'

fresh; git switch -qc feature/choretitle
printf 'x\n' > loader.py; git add .; git commit -qm "chore: 런타임 설정 로더를 바꾼다"
r 1 "$(out_of >/dev/null 2>&1; echo $?)" 'chore: 제목으로도 안 넘어간다'

echo "── 같은 파일 반복 ──"
fresh; git switch -qc feature/repeat
for i in 1 2 3; do printf '%s\n' "$i" > same.txt; printf 't\n' > same_test.txt; git add .; git commit -qm "feat: $i"; done
printf '%s' "$(out_of)" | grep -q "3회  same.txt" && r y y '세 번 건드린 파일을 짚는다' || r y n '세 번 건드린 파일을 짚는다'

echo "── 옛 PR 이 있으면 ──"
fresh; git switch -qc feature/prior
printf 'x\n' > f.txt; printf 't\n' > f_test.txt; git add .; git commit -qm "feat: x"
r 1 "$(GH_UPSTREAM=o/r GH_PRIOR="$(prior 9 MERGED)" out_of >/dev/null 2>&1; echo $?)" '옛 PR 이 있으면 FAIL'

echo "── codex 지적 (PR #51) ──"
# 이름에 test 가 든 운영 파일이 테스트로 잡히면 갈라진 커밋이 통과한다.
fresh; git switch -qc feature/contest
printf 'x\n' > ContestService.java; git add .; git commit -qm "feat: 구현만"
o=$(out_of); printf '%s' "$o" | grep -q "갈라진 커밋" && r y y 'ContestService.java 는 테스트가 아니다' || r y n 'ContestService.java 는 테스트가 아니다'
r 1 "$(out_of >/dev/null 2>&1; echo $?)" '그 커밋 때문에 FAIL 로 끝난다'

fresh; git switch -qc feature/suffix
printf 'x\n' > Foo.java; printf 't\n' > FooTest.java; git add .; git commit -qm "feat: 짝"
printf '%s' "$(out_of)" | grep -q "갈라진 커밋" && r n y 'Test 접미사는 테스트로 본다' || r n n 'Test 접미사는 테스트로 본다'

fresh; git switch -qc feature/dir
mkdir -p test; printf 'x\n' > src.py; printf 't\n' > test/s.py; git add .; git commit -qm "feat: 폴더"
printf '%s' "$(out_of)" | grep -q "갈라진 커밋" && r n y 'test/ 폴더도 테스트로 본다' || r n n 'test/ 폴더도 테스트로 본다'

echo "── 통합 브랜치 자체를 거부한다 ──"
fresh; git switch -qc release; printf 'x\n' > f.txt; git add f.txt; git commit -qm work
r 1 "$(out_of release >/dev/null 2>&1; echo $?)" '인자로 받은 release 에서 작업하면 FAIL'

echo "── codex 지적 (PR #52) ──"
fresh; git switch -qc feature/det
printf 'x\n' > f.txt; printf 't\n' > f_test.txt; git add .; git commit -qm "feat: x"
git checkout -q --detach HEAD
r 1 "$(out_of >/dev/null 2>&1; echo $?)" 'detached HEAD 면 FAIL'
printf '%s' "$(out_of)" | grep -q "detached" && r y y '무엇이 문제인지 알린다' || r y n '무엇이 문제인지 알린다'

# Phase 6 에서만 그 PR 하나를 뺀다. Phase 5 에서는 열린 PR 도 재사용이다 —
# 얼린 PR 에 커밋을 얹는 것을 막아야 한다.
fresh; git switch -qc feature/cur
printf 'x\n' > f.txt; printf 't\n' > f_test.txt; git add .; git commit -qm "feat: x"
r 1 "$(GH_UPSTREAM=o/r GH_PRIOR="$(prior 7 OPEN)" out_of >/dev/null 2>&1; echo $?)" \
    'Phase 5 에서는 열린 PR 도 재사용이다'
r 0 "$(GH_UPSTREAM=o/r GH_PRIOR='' bash "$SCRIPT" main --phase6 7 >/dev/null 2>&1; echo $?)" \
    'Phase 6 에서 넘긴 그 PR 하나는 예외다'

echo "── claude 지적 (PR #53) ──"
fresh; git switch -qc feature/none
printf 'x\n' > f.txt; printf 't\n' > f_test.txt; git add .; git commit -qm "feat: x"
# 열린 PR 이 없을 때 jq 가 깨져 재사용 검사가 통째로 무력해졌다.
r 1 "$(GH_UPSTREAM=o/r GH_PRIOR="$(prior 9 MERGED)" out_of >/dev/null 2>&1; echo $?)" \
    '열린 PR 이 없어도 옛 머지 PR 을 잡는다(jq 가 안 깨진다)'

fresh; git switch -qc feature/zero
r 0 "$(out_of >/dev/null 2>&1; echo $?)" '커밋이 0개면 거짓 FAIL 이 안 난다'
printf '%s' "$(out_of)" | grep -q "갈라진 커밋" && r n y '빈 커밋을 갈라진 것으로 안 본다' || r n n '빈 커밋을 갈라진 것으로 안 본다'

echo "── 접두사 테스트 파일명 (PR #53) ──"
fresh; git switch -qc feature/prefix
printf 'x\n' > foo.py; printf 't\n' > test_foo.py; git add .; git commit -qm "feat: pytest 관례"
printf '%s' "$(out_of)" | grep -q "갈라진 커밋" && r n y 'test_foo.py 를 테스트로 본다' || r n n 'test_foo.py 를 테스트로 본다'

echo "── codex 지적 (PR #54) ──"
# 제목이 docs: 가 아니어도 바뀐 것이 문서뿐이면 예외다.
fresh; git switch -qc feature/docfix
printf 'x\n' > README.md; git add .; git commit -qm "fix: 잘못된 설명을 고친다"
r 0 "$(out_of >/dev/null 2>&1; echo $?)" '문서만 바뀐 커밋은 제목과 무관하게 예외'
fresh; git switch -qc feature/docscope
mkdir -p docs; printf 'x\n' > docs/a.md; git add .; git commit -qm "docs(readme): 갱신"
r 0 "$(out_of >/dev/null 2>&1; echo $?)" 'docs(readme): 형식도 예외'

# 구현 파일 안에 테스트를 두는 관례(Rust·Go).
fresh; git switch -qc feature/colocated
mkdir -p src; printf 'fn f(){}\n#[cfg(test)]\nmod t{ #[test] fn a(){} }\n' > src/lib.rs
git add .; git commit -qm "feat: rust 관례"
r 0 "$(out_of >/dev/null 2>&1; echo $?)" '파일 안에 테스트가 함께 있으면 예외'

# PR 이력 조회가 실패하면 통과로 두지 않는다.
fresh; git switch -qc feature/apifail
printf 'x\n' > f.txt; printf 't\n' > f_test.txt; git add .; git commit -qm "feat: x"
cat > "$BIN/gh" <<'GHF'
#!/usr/bin/env bash
case "$*" in
  *"repo view"*) printf 'o/r\n' ;;
  *"pr list"*)   exit 1 ;;
esac
GHF
chmod +x "$BIN/gh"
r 1 "$(out_of >/dev/null 2>&1; echo $?)" 'PR 이력 조회 실패를 통과로 두지 않는다'
put_gh                                   # 뒤 갈래가 이 망가진 판을 물려받지 않게 원복한다

echo "── claude 지적 (PR #55) ──"
# `it(` 에 경계가 없으면 exit(·commit( 에 걸려 구현만 있는 커밋이 통과한다.
fresh; git switch -qc feature/exitcall
printf 'function f(){ exit(1); commit(x); }\n' > app.js; git add .; git commit -qm "feat: 구현만"
r 1 "$(out_of >/dev/null 2>&1; echo $?)" 'exit(·commit( 을 테스트로 안 본다'

fresh; git switch -qc feature/jstest
printf 'function f(){}\nit("works", () => {});\n' > app.js; git add .; git commit -qm "feat: JS 인라인 테스트"
r 0 "$(out_of >/dev/null 2>&1; echo $?)" 'it( 는 테스트로 본다'

# 원격이 없으면 재사용 검사를 **정말로** 건너뛴다(빈 소유자로 대조하지 않는다).
fresh; git remote remove origin 2>/dev/null; git switch -qc feature/noremote
printf 'x\n' > f.txt; printf 't\n' > f_test.txt; git add .; git commit -qm "feat: x"
r 0 "$(GH_UPSTREAM=o/r GH_PRIOR='{"number":9,"state":"MERGED"}' bash "$SCRIPT" main >/dev/null 2>&1; echo $?)" \
    '원격이 없으면 재사용 검사를 건너뛴다'

echo "── codex 지적 (PR #56) ──"
# gh repo view 실패를 삼키면 재사용 검사가 조용히 꺼진다.
fresh; git switch -qc feature/ghfail
printf 'x\n' > f.txt; printf 't\n' > f_test.txt; git add .; git commit -qm "feat: x"
cat > "$BIN/gh" <<'GHF'
#!/usr/bin/env bash
exit 1
GHF
chmod +x "$BIN/gh"
r 1 "$(out_of >/dev/null 2>&1; echo $?)" 'gh repo view 실패를 통과로 두지 않는다'
put_gh

# 기존 colocated 테스트의 단언만 고친 커밋.
fresh; git switch -qc feature/edittest
mkdir -p src; printf 'fn f(){}\n#[cfg(test)]\nmod t{ #[test] fn a(){ assert!(true); } }\n' > src/lib.rs
git add .; git commit -qm "feat: 처음"
printf 'fn f(){ }\n#[cfg(test)]\nmod t{ #[test] fn a(){ assert_eq!(1,1); } }\n' > src/lib.rs
git add .; git commit -qm "fix: 단언만 고친다"
r 0 "$(out_of >/dev/null 2>&1; echo $?)" '기존 테스트의 단언만 고친 커밋도 예외'

echo "── codex 지적 (PR #58) ──"
# 유일한 테스트를 **지운** 커밋이 「테스트가 함께 있다」로 통과하면 안 된다.
fresh; git switch -qc feature/deltest
mkdir -p src tests
printf 'def f(): pass\n'      > src/app.py
printf 'def test_f(): pass\n' > tests/test_app.py
git add .; git commit -qm "feat: 처음"
printf 'def f(): return 1\n' > src/app.py
git rm -q tests/test_app.py; git add .
git commit -qm "feat: 구현을 고치면서 테스트를 지운다"
r 1 "$(out_of >/dev/null 2>&1; echo $?)" '테스트를 지운 커밋을 통과시키지 않는다'

# 문서를 「구현」으로 세면 테스트만 고친 커밋이 「구현도 있다」로 통과한다.
# 구현이 없으므로 걸려야 맞다.
fresh; git switch -qc feature/docsrc
mkdir -p src tests
printf 'def f(): pass\n'      > src/app.py
printf 'def test_f(): pass\n' > tests/test_app.py
git add .; git commit -qm "feat: 처음"
printf 'def test_f(): assert True\n' > tests/test_app.py
printf '# 설명\n'                    > README.md
git add .; git commit -qm "test: 단언을 채우고 설명을 적는다"
r 1 "$(out_of >/dev/null 2>&1; echo $?)" '테스트+문서만 바뀐 커밋을 통과시키지 않는다'

echo "── codex 지적 (PR #59) ──"
# 테스트만 지운 커밋이 「건드린 게 없다」로 건너뛰어지면 안 된다.
fresh; git switch -qc feature/deleteonly
mkdir -p src tests
printf 'def f(): pass\n'      > src/app.py
printf 'def test_f(): pass\n' > tests/test_app.py
git add .; git commit -qm "feat: 처음"
git rm -q tests/test_app.py; git commit -qm "test: 테스트만 지운다"
r 1 "$(out_of >/dev/null 2>&1; echo $?)" '삭제만 있는 커밋도 분류한다'

# 옛 테스트가 파일에 남아 있다는 이유만으로 구현 커밋이 통과하면 안 된다.
fresh; git switch -qc feature/staletest
mkdir -p src
printf 'fn f()->i32{1}\n#[cfg(test)]\nmod t{ #[test] fn a(){ assert_eq!(1,1); } }\n' > src/lib.rs
git add .; git commit -qm "feat: 처음"
printf 'fn f()->i32{2}\n#[cfg(test)]\nmod t{ #[test] fn a(){ assert_eq!(1,1); } }\n' > src/lib.rs
git add .; git commit -qm "feat: 구현만 고친다"
printf '%s' "$(out_of)" | grep -q "눈으로 확인한다" \
  && r y y '옛 테스트가 남은 구현 커밋을 목록에 올린다' || r y n '옛 테스트가 남은 구현 커밋을 목록에 올린다'

# 반대 갈래 — 같은 커밋에서 단언도 고쳤으면 통과해야 한다.
fresh; git switch -qc feature/bothchanged
mkdir -p src
printf 'fn f()->i32{1}\n#[cfg(test)]\nmod t{ #[test] fn a(){ assert_eq!(f(),1); } }\n' > src/lib.rs
git add .; git commit -qm "feat: 처음"
printf 'fn f()->i32{2}\n#[cfg(test)]\nmod t{ #[test] fn a(){ assert_eq!(f(),2); } }\n' > src/lib.rs
git add .; git commit -qm "feat: 구현과 단언을 함께 고친다"
r 0 "$(out_of >/dev/null 2>&1; echo $?)" '구현과 단언을 함께 고치면 통과한다'

# 이름이 문서 토큰으로 시작하는 운영 소스를 문서로 보면 안 된다.
fresh; git switch -qc feature/licensemgr
mkdir -p src
printf 'class LICENSEManager {}\n' > src/LICENSEManager.java
git add .; git commit -qm "feat: 라이선스 관리자를 넣는다"
r 1 "$(out_of >/dev/null 2>&1; echo $?)" 'LICENSEManager.java 를 문서로 보지 않는다'

echo "── codex 지적 (PR #60) ──"
# 운영 코드에 단언 한 줄만 넣은 커밋이 「테스트를 고쳤다」로 통과하면 안 된다.
# 테스트 영역은 파일 아래쪽이므로 위쪽만 건드린 것을 가려내야 한다.
fresh; git switch -qc feature/prodassert
mkdir -p src
{ printf 'fn f(x:i32)->i32{ x }\n'
  printf '#[cfg(test)]\n'
  printf 'mod t{ use super::*; #[test] fn a(){ assert_eq!(f(1),1); } }\n'; } > src/lib.rs
git add .; git commit -qm "feat: 처음"
{ printf 'fn f(x:i32)->i32{ assert!(x>0); x }\n'
  printf '#[cfg(test)]\n'
  printf 'mod t{ use super::*; #[test] fn a(){ assert_eq!(f(1),1); } }\n'; } > src/lib.rs
git add .; git commit -qm "feat: 운영 코드에 단언만 넣는다"
printf '%s' "$(out_of)" | grep -q "눈으로 확인한다" \
  && r y y '운영 코드만 고친 colocated 커밋을 목록에 올린다' || r y n '운영 코드만 고친 colocated 커밋을 목록에 올린다'

# 반대 갈래 — 테스트 영역을 고쳤으면 통과해야 한다.
fresh; git switch -qc feature/testarea
mkdir -p src
{ printf 'fn f(x:i32)->i32{ x }\n'
  printf '#[cfg(test)]\n'
  printf 'mod t{ use super::*; #[test] fn a(){ assert_eq!(f(1),1); } }\n'; } > src/lib.rs
git add .; git commit -qm "feat: 처음"
{ printf 'fn f(x:i32)->i32{ x*2 }\n'
  printf '#[cfg(test)]\n'
  printf 'mod t{ use super::*; #[test] fn a(){ assert_eq!(f(1),2); } }\n'; } > src/lib.rs
git add .; git commit -qm "feat: 구현과 테스트를 함께 고친다"
r 0 "$(out_of >/dev/null 2>&1; echo $?)" '테스트 영역을 고쳤으면 통과한다'

# 기능을 걷어내며 구현과 테스트를 **함께 지운** 커밋은 정상이다.
fresh; git switch -qc feature/removeboth
mkdir -p src tests
printf 'def f(): pass\n'      > src/app.py
printf 'def test_f(): pass\n' > tests/test_app.py
printf 'def g(): pass\n'      > src/keep.py
git add .; git commit -qm "feat: 처음"
git rm -q src/app.py tests/test_app.py
git commit -qm "feat: 기능을 구현과 테스트째로 걷어낸다"
r 0 "$(out_of >/dev/null 2>&1; echo $?)" '구현과 테스트를 함께 지운 커밋은 통과한다'

echo "── codex 지적 (PR #62) ──"
# `src/doc/` 는 운영 패키지일 수 있다 — 문서로 보고 검사를 건너뛰면 안 된다.
fresh; git switch -qc feature/docpkg
mkdir -p src/doc
printf 'def parse(): pass\n' > src/doc/parser.py
git add .; git commit -qm "feat: 파서를 넣는다"
r 1 "$(out_of >/dev/null 2>&1; echo $?)" 'src/doc/ 를 문서로 보지 않는다'

# 최상위 docs/ 는 여전히 문서다.
fresh; git switch -qc feature/realdocs
mkdir -p docs
printf '# 설명\n' > docs/guide.md
git add .; git commit -qm "docs: 안내를 적는다"
r 0 "$(out_of >/dev/null 2>&1; echo $?)" '최상위 docs/ 는 문서로 본다'

# 1초 폴링을 남겨 두면 시험 전체가 몇 분 멈춘 것처럼 보인다.
r 0 "$(grep -v '^[[:space:]]*#' "$SCRIPT" | grep -c 'sleep 1;' || true)" \
   'bounded 가 1초 단위로 폴링하지 않는다'

# push URL 이 슬래시로 끝나면 소유자가 빈 값이 되어 Phase 5 가 통째로 막혔다.
# 문자열 대조가 아니라 **실제로 그런 URL 을 물려 돌려 본다.**
fresh; git switch -qc feature/trailslash
mkdir -p src; printf 'x\n' > src/a.py; printf 't\n' > src/a_test.py
git add .; git commit -qm "feat: x"
git remote set-url --push origin "$(git remote get-url origin)/"
r 0 "$(out_of >/dev/null 2>&1; echo $?)" 'push URL 이 슬래시로 끝나도 돈다'

echo "── codex 지적 (PR #63) ──"
# 기존 구현 파일에 테스트 블록만 붙인 커밋은 테스트-only 다 — 걸려야 한다.
#
# 바탕 커밋은 **main 에 두고 push 한다.** 판정 범위가 origin/main..HEAD 이므로,
# push 하지 않으면 그 커밋도 범위에 남아 무엇을 재는지 흐려진다.
fresh
mkdir -p src; printf 'fn f()->i32{1}\n' > src/lib.rs
git add .; git commit -qm "base"; git push -q origin main 2>/dev/null
git switch -qc feature/testonlyinline
{ printf 'fn f()->i32{1}\n'
  printf '#[cfg(test)]\n'
  printf 'mod t{ #[test] fn a(){ assert_eq!(1,1); } }\n'; } > src/lib.rs
git add .; git commit -qm "test: 테스트 블록만 붙인다"
printf '%s' "$(out_of)" | grep -q "눈으로 확인한다" \
  && r y y '인라인 테스트만 추가한 커밋도 목록에 올린다' || r y n '인라인 테스트만 추가한 커밋도 목록에 올린다'

# 반대 갈래 — 구현도 함께 바뀌면 통과한다.
fresh
mkdir -p src; printf 'fn f()->i32{1}\n' > src/lib.rs
git add .; git commit -qm "base"; git push -q origin main 2>/dev/null
git switch -qc feature/bothinline
{ printf 'fn f()->i32{7}\n'
  printf '#[cfg(test)]\n'
  printf 'mod t{ #[test] fn a(){ assert_eq!(f(),7); } }\n'; } > src/lib.rs
git add .; git commit -qm "feat: 구현을 고치고 테스트를 붙인다"
r 0 "$(out_of >/dev/null 2>&1; echo $?)" '구현과 인라인 테스트를 함께 넣으면 통과한다'

echo "── codex 지적 (PR #64) ──"
# 구현과 인라인 테스트를 **한 커밋에서 함께 걷어내는** 것은 규칙에 맞는 모양이다.
fresh
mkdir -p src
{ printf 'fn keep(){}\n'
  printf 'fn gone()->i32{1}\n'
  printf '#[cfg(test)]\n'
  printf 'mod t{ use super::*; #[test] fn a(){ assert_eq!(gone(),1); } }\n'; } > src/lib.rs
git add .; git commit -qm "base"; git push -q origin main 2>/dev/null
git switch -qc feature/removeinline
printf 'fn keep(){}\n' > src/lib.rs      # 구현과 테스트를 함께 지운다
git add .; git commit -qm "feat: 기능을 인라인 테스트째로 걷어낸다"
r 0 "$(out_of >/dev/null 2>&1; echo $?)" '구현과 인라인 테스트를 함께 지운 커밋은 통과한다'

# gh 조회가 한 번이어야 한다 — 두 번 부르면 뒤쪽 실패로 호스트 대조가 꺼진다.
r 1 "$(grep -c 'json parent,nameWithOwner,url' "$SCRIPT" || true)" \
   'upstream NWO 와 URL 을 한 호출로 받는다'
r 0 "$(grep -v '^[[:space:]]*#' "$SCRIPT" | grep -c 'json parent,url' || true)" \
   'URL 을 따로 조회하지 않는다'

echo "── codex 지적 (PR #65) ──"
# 마지막 인라인 테스트 블록만 걷어낸 커밋은 test-only 다 — 걸려야 한다.
fresh
mkdir -p src
{ printf 'fn keep()->i32{1}\n'
  printf '#[cfg(test)]\n'
  printf 'mod t{ use super::*; #[test] fn a(){ assert_eq!(keep(),1); } }\n'; } > src/lib.rs
git add .; git commit -qm "base"; git push -q origin main 2>/dev/null
git switch -qc feature/droptest
printf 'fn keep()->i32{1}\n' > src/lib.rs      # 구현은 그대로, 테스트만 지운다
git add .; git commit -qm "test: 테스트 블록만 걷어낸다"
printf '%s' "$(out_of)" | grep -q "눈으로 확인한다" \
  && r y y '마지막 인라인 테스트만 지운 커밋도 목록에 올린다' || r y n '마지막 인라인 테스트만 지운 커밋도 목록에 올린다'

# fork 인데 upstream 원격이 없으면 fork 의 origin 으로 떨어지지 않는다.
fresh; git switch -qc feature/forkNoUp
printf 'x\n' > f.txt; printf 't\n' > f_test.txt; git add .; git commit -qm "feat: x"
r 1 "$(GH_PARENT=up/stream GH_UPSTREAM=me/fork out_of >/dev/null 2>&1; echo $?)" \
   'fork 인데 upstream 원격이 없으면 멈춘다'
printf '%s' "$(GH_PARENT=up/stream GH_UPSTREAM=me/fork out_of)" \
  | grep -q "git remote add upstream" \
  && r y y '어떻게 고치는지 알려준다' || r y n '어떻게 고치는지 알려준다'

# fork 가 아니면 폴백이 맞는 답을 준다 — 막지 않는다.
fresh; git switch -qc feature/notfork
printf 'x\n' > f.txt; printf 't\n' > f_test.txt; git add .; git commit -qm "feat: x"
r 0 "$(GH_UPSTREAM=o/r out_of >/dev/null 2>&1; echo $?)" \
   'fork 가 아니면 원격 이름이 달라도 돈다'

echo "── codex 지적 (PR #66) ──"
# 구현과 인라인 테스트가 든 파일을 **통째로** 지운 커밋은 정상이다.
fresh
mkdir -p src
{ printf 'fn gone()->i32{1}\n'
  printf '#[cfg(test)]\n'
  printf 'mod t{ use super::*; #[test] fn a(){ assert_eq!(gone(),1); } }\n'; } > src/gone.rs
printf 'fn keep(){}\n' > src/keep.rs
git add .; git commit -qm "base"; git push -q origin main 2>/dev/null
git switch -qc feature/dropfile
git rm -q src/gone.rs
git commit -qm "feat: 기능 파일을 통째로 걷어낸다"
r 0 "$(out_of >/dev/null 2>&1; echo $?)" '인라인 테스트가 든 파일을 통째로 지운 커밋은 통과한다'

# PR 이력 조회에 Enterprise 호스트를 붙인다.
r 1 "$(grep -c 'UP_HOST=$(host_of' "$SCRIPT" || true)" \
   'PR 이력 조회에 호스트를 붙인다'
r 0 "$(grep -v '^[[:space:]]*#' "$SCRIPT" | grep -c 'pr list --repo "\$UPSTREAM"' || true)" \
   '이름만으로 조회하지 않는다'

# 진단에 자격 증명이 실리면 안 된다.
r 1 "$(grep -c '^redact()' "$SCRIPT" || true)" 'URL 을 가리는 함수가 있다'

# 기본 포트는 떼고 사내 포트는 구분한다. 함수만 뽑아 별도 파일로 읽힌다 —
# 중첩 heredoc 안에서는 바깥 변수가 안 넘어간다.
FN=$(mktemp); sed -n '/^host_of()/,/^}/p' "$SCRIPT" > "$FN"
r "github.com"      "$(. "$FN"; host_of ssh://git@github.com:22/me/w.git)" 'ssh 기본 포트 22 를 뗀다'
r "github.com"      "$(. "$FN"; host_of https://github.com:443/me/w)"      'https 기본 포트 443 을 뗀다'
r "git.ex.com:8443" "$(. "$FN"; host_of https://git.ex.com:8443/me/w)"     '사내 포트는 남긴다'
rm -f "$FN"

echo "── claude 지적 (PR #68) ──"
# push URL 이 둘이면 **두 번째 소유자**의 옛 PR 도 걸려야 한다.
# 앞 라운드에는 소유자를 모으기만 하고 첫 것으로만 걸러서 동작이 그대로였다.
fresh; git switch -qc feature/twoowners
printf 'x\n' > f.txt; printf 't\n' > f_test.txt; git add .; git commit -qm "feat: x"
git remote set-url --push origin "https://host/first/work.git"
git remote set-url --add --push origin "https://host/second/work.git"
# 옛 PR 의 소유자가 **두 번째** 다.
r 1 "$(GH_UPSTREAM=o/r \
       GH_PRIOR='{"number":9,"state":"MERGED","headRepositoryOwner":{"login":"second"}}' \
       out_of >/dev/null 2>&1; echo $?)" \
   '두 번째 push URL 소유자의 옛 PR 도 잡는다'

# 관계없는 소유자의 PR 은 안 걸려야 한다 — 좁힌 것이 넓어지면 안 된다.
r 0 "$(GH_UPSTREAM=o/r \
       GH_PRIOR='{"number":9,"state":"MERGED","headRepositoryOwner":{"login":"stranger"}}' \
       out_of >/dev/null 2>&1; echo $?)" \
   '내 소유자가 아닌 PR 은 안 잡는다'

echo "── codex 지적 (PR #68) ──"
# merge 커밋은 기본으로 경로를 안 낸다 — 검사를 건너뛰면 안 된다.
fresh; git switch -qc feature/withmerge
printf 'base2\n' > b2.txt; printf 't\n' > b2_test.txt; git add .; git commit -qm "feat: 짝"
git switch -qc side/impl
printf 'impl\n' > only_impl.py; git add .; git commit -qm "feat: 구현만"
git switch -q feature/withmerge
git merge -q --no-ff side/impl -m "merge: side 를 들인다" 2>/dev/null
r 1 "$(out_of >/dev/null 2>&1; echo $?)" 'merge 커밋으로 들여온 구현만 있는 변경도 잡는다'

echo "── codex 지적 (PR #70) ──"
# 구현·테스트 짝을 지우면서 **딴 테스트만** 하나 더한 커밋은 갈라진 테스트 커밋이다.
fresh
mkdir -p src tests
printf 'def a(): pass\n'      > src/a.py
printf 'def test_a(): pass\n' > tests/test_a.py
git add .; git commit -qm base; git push -q origin main 2>/dev/null
git switch -qc feature/orphantest
git rm -q src/a.py tests/test_a.py
# `git rm` 이 빈 tests/ 를 지운다 — 다시 만들어야 파일을 넣을 수 있다.
mkdir -p tests
printf 'def test_orphan(): pass\n' > tests/test_orphan.py
git add .; git commit -qm "test: 짝을 지우고 딴 테스트를 더한다"
r 1 "$(out_of >/dev/null 2>&1; echo $?)" '짝을 지우면서 딴 테스트만 더한 커밋을 잡는다'

echo "── codex 지적 (PR #71) ──"
# 확장자 없는 README 만 더한 커밋은 문서 커밋이다.
fresh; git switch -qc feature/plainreadme
printf '설명\n' > README
git add .; git commit -qm "docs: 설명을 적는다"
r 0 "$(out_of >/dev/null 2>&1; echo $?)" '확장자 없는 README 를 문서로 본다'

# 이름이 문서 토큰으로 시작하는 소스는 여전히 소스다.
fresh; git switch -qc feature/readmeparser
mkdir -p src; printf 'class READMEParser {}\n' > src/READMEParser.java
git add .; git commit -qm "feat: 파서를 넣는다"
r 1 "$(out_of >/dev/null 2>&1; echo $?)" 'READMEParser.java 는 소스로 본다'

echo
echo "════ 합계: OK $pass / FAIL $fail ════"
[ "$fail" -eq 0 ]
