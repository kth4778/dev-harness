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

        # 셸 스크립트만 본다 — 이름이 *.sh 거나 첫 줄이 sh 셔뱅.
        # **실행 비트로 고르지 않는다.** 로컬에서 비트가 벗겨진 파일이 검사에서
        # 빠져, 로컬 PASS·CI FAIL 로 갈렸다(2026-08-14 실물 — stamp-guard 가
        # 로컬에서 644 였다). 비트는 환경 따라 다르고 셔뱅은 내용이라 같다.
        case "$f" in
            *.sh) : ;;
            *)  first=$(head -n1 "$f" 2>/dev/null || true)
                case "$first" in '#!'*sh*) : ;; *) continue ;; esac ;;
        esac

        # **논리 줄로 결합해** 찾는다. 줄 단위로만 보면 백슬래시 연속이나
        # 줄 끝 `|` 뒤 다음 줄의 grep -q (trailing-pipe) 를 놓친다 — 정확히
        # 같은 SIGPIPE 함정인데 PASS 였다 (codex·claude, PR #86).
        # q 는 결합 플래그의 어느 자리에나 올 수 있고(-qE·-Eq), 긴 이름
        # (--quiet·--silent)도 있다.
        hits=$(awk '
            {
                if (buf == "") { start = NR; buf = $0 } else { buf = buf " " $0 }
                if (buf ~ /\\$/)              { sub(/\\$/, " ", buf); next }
                if (buf ~ /\|[[:space:]]*$/)   next
                print start ":" buf; buf = ""
            }
            END { if (buf != "") print start ":" buf }
        ' "$f" 2>/dev/null \
                 | grep -E '\|[[:space:]]*grep[[:space:]]+(-[a-zA-Z]*q[a-zA-Z]*([[:space:]]|$)|--quiet|--silent)' \
                 | grep -vE '^[0-9]+:[[:space:]]*#' || true)
        if [ -n "$hits" ]; then
            printf 'FAIL — 파이프 뒤 grep -q: %s\n' "$f" >&2
            printf '%s\n' "$hits" | sed 's/^/    /' >&2
            fail=1
        fi
    done <<FILES
$(find "$root" -type f 2>/dev/null | sort)
FILES
done

if [ "$fail" -eq 0 ]; then
    printf 'PASS — 파이프 뒤 grep -q 없음\n'
fi
exit "$fail"
