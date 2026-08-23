#!/usr/bin/env bash
# skills/build/scripts/panel-tally.py 의 갈래를 잰다.
#
# 세 갈래를 다 담는다 — 채택되어야 할 것이 채택되나 · 미채택되어야 할 것이
# 미채택되나 · 판정 근거가 없을 때. RULES.md 「훅을 고칠 때」와 같은 원칙이다.
# 이 스크립트는 훅이 아니지만 게이트를 움직이므로 같은 잣대로 잰다.
ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
SCRIPT="$ROOT/skills/build/scripts/panel-tally.py"
if [ ! -f "$SCRIPT" ]; then
    echo "  [SKIP] $SCRIPT 가 없다 — 훅만 담긴 옛 트리로 보인다"
    exit 0
fi

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

pass=0; fail=0
r() { if [ "$1" = "$2" ]; then pass=$((pass+1)); printf '  [OK ] '; else fail=$((fail+1)); printf '  [FAIL] '; fi
     printf '기대 %s / 실제 %s  %s\n' "$1" "$2" "$3"; }

# 표 하나를 파일로 놓는다.  vote <디렉터리> <이름> <발견> <렌즈> <판정> [증거]
vote() {
    d="$W/$1"; mkdir -p "$d"
    ev="${6-}"
    if [ -n "$ev" ]; then ev="\"evidence\": \"$ev\","; fi
    cat > "$d/$2.json" <<JSON
{"finding_id": "$3", "lens": "$4", $ev "verdict": "$5"}
JSON
}

run() { python3 "$SCRIPT" "$W/$1" 2>&1; }
st()  { python3 "$SCRIPT" "$W/$1" >/dev/null 2>&1; echo $?; }
keeps() { run "$1" | grep -c '^KEEP' || true; }
drops() { run "$1" | grep -c '^DROP' || true; }

echo "── 채택되어야 할 것이 채택되나 ──"

vote a v1 F1 reachability TRUE_POSITIVE  "src/A.java:10"
vote a v2 F1 impact       TRUE_POSITIVE  "src/A.java:11"
vote a v3 F1 defenses     FALSE_POSITIVE "src/A.java:12"
r 1 "$(keeps a)" "3표 중 2 인정 → 채택"

vote b v1 F1 reachability TRUE_POSITIVE  "src/A.java:10"
vote b v2 F1 impact       TRUE_POSITIVE  "src/A.java:11"
vote b v3 F1 defenses     TRUE_POSITIVE  "src/A.java:12"
r 1 "$(keeps b)" "3표 만장 → 채택"

echo "── 미채택되어야 할 것이 미채택되나 ──"

vote c v1 F1 reachability TRUE_POSITIVE  "src/A.java:10"
vote c v2 F1 impact       FALSE_POSITIVE "src/A.java:11"
vote c v3 F1 defenses     FALSE_POSITIVE "src/A.java:12"
r 1 "$(drops c)" "3표 중 1 인정 → 미채택"

# 여기가 이 스크립트의 존재 이유다. 표가 모자라면 통과시키지 않는다.
vote d v1 F1 reachability TRUE_POSITIVE "src/A.java:10"
vote d v2 F1 impact       TRUE_POSITIVE "src/A.java:11"
r 1 "$(drops d)" "투표자 2/3 — 표가 모자라면 인정 2표여도 미채택"

vote e v1 F1 reachability TRUE_POSITIVE  "src/A.java:10"
vote e v2 F1 impact       TRUE_POSITIVE  "src/A.java:11"
vote e v3 F1 defenses     FALSE_POSITIVE "src/A.java:12"
# 렌즈를 겹치지 않게 넷째를 준다 — 겹치면 렌즈 검사가 먼저 잡아
# 이 갈래가 투표자 수를 재지 못한다(주입으로 드러났다).
vote e v4 F1 scope        TRUE_POSITIVE  "src/A.java:13"
r 1 "$(drops e)" "투표자 4/3 — 기대보다 많아도 미채택"

# 증거 없는 표는 무효다. 유효표가 줄어 결국 표가 모자란다.
vote f v1 F1 reachability TRUE_POSITIVE  "src/A.java:10"
vote f v2 F1 impact       TRUE_POSITIVE
vote f v3 F1 defenses     TRUE_POSITIVE  "src/A.java:12"
r 1 "$(drops f)" "증거 없는 표는 무효 → 유효 2/3 → 미채택"

# 같은 렌즈 둘은 독립이 아니다. claude-security 의 one voter per lens.
vote g v1 F1 reachability TRUE_POSITIVE  "src/A.java:10"
vote g v2 F1 reachability TRUE_POSITIVE  "src/A.java:11"
vote g v3 F1 defenses     FALSE_POSITIVE "src/A.java:12"
r 1 "$(drops g)" "렌즈가 겹치면 독립이 아니다 → 미채택"

vote h v1 F1 reachability YES            "src/A.java:10"
vote h v2 F1 impact       TRUE_POSITIVE  "src/A.java:11"
vote h v3 F1 defenses     TRUE_POSITIVE  "src/A.java:12"
r 1 "$(drops h)" "모르는 판정값은 무효표 → 유효 2/3 → 미채택"

echo "── 판정 근거가 없을 때 ──"

mkdir -p "$W/i"
r 2 "$(st i)" "표가 하나도 없으면 집계 불가(exit 2)"

mkdir -p "$W/j"; printf '{ 깨진' > "$W/j/v1.json"
r 2 "$(st j)" "JSON 이 깨지면 집계 불가(exit 2) — 조용히 0표로 세지 않는다"

r 2 "$(st does-not-exist)" "없는 경로는 집계 불가(exit 2)"

echo "── 발견이 여럿일 때 ──"

vote k v1 F1 reachability TRUE_POSITIVE  "src/A.java:10"
vote k v2 F1 impact       TRUE_POSITIVE  "src/A.java:11"
vote k v3 F1 defenses     FALSE_POSITIVE "src/A.java:12"
vote k v4 F2 reachability FALSE_POSITIVE "src/B.java:20"
vote k v5 F2 impact       FALSE_POSITIVE "src/B.java:21"
vote k v6 F2 defenses     FALSE_POSITIVE "src/B.java:22"
r 1 "$(keeps k)" "발견 둘 — 하나만 채택"
r 1 "$(drops k)" "발견 둘 — 하나는 미채택"
r 0 "$(st k)" "집계가 됐으면 미채택이 있어도 exit 0"

echo "── 문서가 시킨 방식으로 실제로 도나 ──"

# 여기까지의 갈래는 전부 `python3 "$SCRIPT"` 로 우회 호출한다. 그래서 실행
# 비트가 빠져도 열넷이 다 초록이었다 — 정작 RULES.md 와 build/SKILL.md 는
# 경로만으로 부르라고 지시하는데 그 호출은 permission denied 로 죽는다
# (claude, PR #105). 그물이 이름보다 좁았다.
vote z v1 F1 reachability TRUE_POSITIVE  "src/A.java:10"
vote z v2 F1 impact       TRUE_POSITIVE  "src/A.java:11"
vote z v3 F1 defenses     FALSE_POSITIVE "src/A.java:12"
"$SCRIPT" "$W/z" >/dev/null 2>&1
r 0 "$?" "python3 접두어 없이 경로만으로 실행된다"

# 로컬 파일 권한은 chmod 로 맞춰져 있어도 **git 에 저장된 모드**는 다를 수 있다.
# 이 저장소는 core.fileMode=false 라 로컬 chmod 가 git 으로 가지 않는다 —
# 배포되는 것은 git 이 들고 있는 모드다.
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    mode=$(git -C "$ROOT" ls-files -s -- skills/build/scripts/panel-tally.py 2>/dev/null | awk '{print $1}')
    r 100755 "${mode:-없음}" "git 에 실행 비트가 저장돼 있나 (core.fileMode=false 면 chmod 로는 안 간다)"
else
    echo "  [SKIP] git 저장소가 아니다 — 저장된 모드를 볼 수 없다"
fi

printf '\n════ 합계: OK %s / FAIL %s ════\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
