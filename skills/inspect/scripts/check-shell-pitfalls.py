#!/usr/bin/env python3
"""셸 함정 검사 — 이 저장소에서 반복해서 밟은 패턴을 기계로 잡는다.

왜 있나 (2026-08-14 회고 승격 ⑤):
  「파이프 뒤 grep -q」 함정을 한 세션에서 **열여섯 번** 밟았다. pipefail
  아래서 grep 이 매치 즉시 닫히면 앞 명령이 SIGPIPE 로 죽고, 그 141 이
  판정을 뒤집는다 — 차단이 통째로 사라지는데 에러도 안 난다. 규칙(주석)은
  이미 있었는데도 밟았으므로, 규칙이 아니라 기계가 잡는다.

왜 파이썬인가 (2026-08-14, 이식):
  셸 판(sh)은 인용·플래그 위치를 정규식으로 흉내내다 네 라운드 연속 지적을
  받았다. 여기서는 shlex — 진짜 셸 토크나이저 — 로 논리 줄을 토큰화하므로
  인용 안의 예시 문자열, 플래그 순서, 결합 플래그가 **문법 수준에서** 갈린다.

잡는 것:
  - 파이프 뒤 `grep -q` (주석 줄 제외) — 어느 위치·어느 표기든

못 잡는 것 (규칙 4 — 능력을 정직하게):
  - `cmd || true` 로 명령 실패를 삼키고 그 결과로 판정하는 것. `grep -c
    || true` 같은 정당한 사용과 기계로 가를 수 없다 — 리뷰가 본다
  - 파이프 중간의 `head`. 실사고 이력이 없어 범위 밖에 뒀다

사용: check-shell-pitfalls.py [검사할 루트...]
  인자가 없으면 플러그인의 hooks/ 와 skills/*/scripts/ 를 본다.
  시험은 임시 폴더를 인자로 넘겨 결함 주입을 확인한다.
"""
import os
import re
import shlex
import sys

# 대상 프로젝트 루트를 통째로 받을 수 있으므로 남의 코드 무더기도 뺀다.
# tests/ 는 의도적으로 함정을 담아 두는 자리다.
SKIP_DIRS = {"tests", ".git", "node_modules", "vendor", "build", ".gradle"}
QUIET_FLAGS = {"--quiet", "--silent"}


def is_shell_script(path):
    """이름이 *.sh 거나 첫 줄이 sh 셔뱅이면 참.

    **실행 비트로 고르지 않는다.** 로컬에서 비트가 벗겨진 파일이 검사에서
    빠져, 로컬 PASS·CI FAIL 로 갈렸다(2026-08-14 실물). 비트는 환경 따라
    다르고 셔뱅은 내용이라 같다.
    """
    if path.endswith(".sh"):
        return True
    try:
        with open(path, "rb") as f:
            first = f.readline(120)
    except OSError:
        return False
    return first.startswith(b"#!") and b"sh" in first


def logical_lines(text):
    """(시작 줄 번호, 결합된 논리 줄) 을 낸다.

    줄 단위로만 보면 백슬래시 연속이나 줄 끝 `|` 뒤 다음 줄의 grep -q
    (trailing-pipe) 를 놓친다 — 정확히 같은 SIGPIPE 함정인데 PASS 였다
    (codex·claude, PR #86).
    """
    buf, start = "", 0
    for n, line in enumerate(text.splitlines(), 1):
        if not buf:
            start, buf = n, line
        else:
            buf += " " + line
        if buf.rstrip().endswith("\\"):
            buf = buf.rstrip()[:-1] + " "
            continue
        if buf.rstrip().endswith("|"):
            continue
        yield start, buf
        buf = ""
    if buf:
        yield start, buf


def is_quiet_grep_segment(tokens):
    """파이프 한 구간의 토큰들이 「quiet 모드 grep」인가.

    shlex 가 인용을 벗긴 **값**을 주므로, -q 가 결합 플래그의 어느 자리에
    있든(-qE·-Eq), 다른 옵션 뒤(-E --quiet)에 오든, 표기가 무엇이든
    토큰 검사 하나로 끝난다 — sh 판이 정규식 네 개로 쫓던 것이다.
    """
    if not tokens or os.path.basename(tokens[0]) != "grep":
        return False
    for t in tokens[1:]:
        if t in QUIET_FLAGS:
            return True
        if re.fullmatch(r"-[A-Za-z]*q[A-Za-z]*", t):
            return True
    return False


def scan_line(line):
    """논리 줄 하나에 「파이프 뒤 quiet grep」이 있으면 참.

    shlex 에 punctuation_chars 를 주면 `|`·`;`·`&` 가 **별도 토큰**이 된다 —
    인용 안의 `|`(예시 문자열)는 자연히 토큰이 아니므로, sh 판처럼 인용을
    지우는 전처리가 필요 없다.
    """
    lex = shlex.shlex(line, posix=True, punctuation_chars="|;&()")
    lex.whitespace_split = True
    try:
        tokens = list(lex)
    except ValueError:
        # 닫히지 않은 인용 등 — 셸 문법이 아닌 파일일 수 있다. 판정하지
        # 않고 넘기면 거짓 통과가 되므로, 논리 줄 원문으로 보수적으로 본다.
        return bool(re.search(r"\|\s*grep\s+[^|;&]*(-[A-Za-z]*q|--quiet|--silent)", line))
    seg = []
    prev_pipe = False
    for t in tokens:
        if t in {"|", ";", "&", "&&", "||", "(", ")"}:
            if prev_pipe and is_quiet_grep_segment(seg):
                return True
            prev_pipe = t == "|"
            seg = []
        else:
            seg.append(t)
    return prev_pipe and is_quiet_grep_segment(seg)


def scan_file(path):
    """파일 하나를 훑어 걸린 (줄 번호, 원문) 목록을 낸다."""
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return []
    hits = []
    for start, line in logical_lines(text):
        if line.lstrip().startswith("#"):
            continue
        if scan_line(line):
            hits.append((start, line.strip()))
    return hits


def iter_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for name in sorted(filenames):
            # 자기 자신(sh 시절 포함)은 뺀다 — 패턴 문자열이 문서로 들어 있다.
            if name.startswith("check-shell-pitfalls."):
                continue
            yield os.path.join(dirpath, name)


def main(argv):
    if len(argv) > 1:
        roots = argv[1:]
    else:
        base = os.environ.get("CLAUDE_PLUGIN_ROOT") or os.path.abspath(
            os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")
        )
        roots = [os.path.join(base, "hooks")]
        skills = os.path.join(base, "skills")
        if os.path.isdir(skills):
            for d in sorted(os.listdir(skills)):
                scripts = os.path.join(skills, d, "scripts")
                if os.path.isdir(scripts):
                    roots.append(scripts)

    fail = 0
    for root in roots:
        for f in iter_files(root):
            if not is_shell_script(f):
                continue
            hits = scan_file(f)
            if hits:
                print("FAIL — 파이프 뒤 grep -q: %s" % f, file=sys.stderr)
                for n, line in hits:
                    print("    %d:%s" % (n, line), file=sys.stderr)
                fail = 1
    if fail == 0:
        print("PASS — 파이프 뒤 grep -q 없음")
    return fail


if __name__ == "__main__":
    sys.exit(main(sys.argv))
