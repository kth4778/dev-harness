#!/usr/bin/env bash
# 셸 함정 검사 — 이 저장소에서 반복해서 밟은 패턴을 기계로 잡는다.
#
# 왜 있나 (2026-08-14 회고 승격 ⑤):
#   「파이프 뒤 grep -q」 함정을 한 세션에서 **열 번** 밟았다. pipefail 아래서
#   grep 이 매치 즉시 닫히면 앞 명령이 SIGPIPE 로 죽고, 그 141 이 판정을
#   뒤집는다 — 차단이 통째로 사라지는데 에러도 안 난다. 규칙(주석)은 이미
#   있었는데도 밟았으므로, 규칙이 아니라 기계가 잡는다.
#
# 잡는 것:
#   - 파이프 뒤 `grep -q` (주석 줄 제외)
#
# 못 잡는 것 (규칙 4 — 능력을 정직하게):
#   - `cmd || true` 로 명령 실패를 삼키고 그 결과로 판정하는 것. `grep -c
#     || true` 같은 정당한 사용과 기계로 가를 수 없다 — 리뷰가 본다
#   - 파이프 중간의 `head`. 실사고 이력이 없어 범위 밖에 뒀다
#
# 사용: check-shell-pitfalls.sh [검사할 루트...]
#   인자가 없으면 플러그인의 hooks/ 와 skills/*/scripts/ 를 본다.
#   시험은 임시 폴더를 인자로 넘겨 결함 주입을 확인한다.

set -uo pipefail

if [ "$#" -gt 0 ]; then
    roots=( "$@" )
else
    base="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
    roots=( "$base/hooks" )
    for d in "$base"/skills/*/scripts; do
        [ -d "$d" ] && roots+=( "$d" )
    done
fi

fail=0
for root in "${roots[@]}"; do
    while IFS= read -r f; do
        # 시험 폴더는 뺀다 — 의도적으로 함정을 담아 두는 자리다.
        case "$f" in */tests/*) continue ;; esac
        # 자기 자신도 뺀다 — 패턴 문자열이 문서로 들어 있다.
        [ "$(basename "$f")" = "check-shell-pitfalls.sh" ] && continue

        # 주석 줄을 제외하고 파이프 뒤 grep -q 를 찾는다.
        hits=$(grep -nE '\|[[:space:]]*grep[[:space:]]+-[a-zA-Z]*q' "$f" 2>/dev/null \
                 | grep -vE '^[0-9]+:[[:space:]]*#' || true)
        if [ -n "$hits" ]; then
            printf 'FAIL — 파이프 뒤 grep -q: %s\n' "$f" >&2
            printf '%s\n' "$hits" | sed 's/^/    /' >&2
            fail=1
        fi
    done <<FILES
$(find "$root" -type f \( -name '*.sh' -o -perm -u+x \) 2>/dev/null | sort)
FILES
done

if [ "$fail" -eq 0 ]; then
    printf 'PASS — 파이프 뒤 grep -q 없음\n'
fi
exit "$fail"
