#!/usr/bin/env python3
"""셸 함정 검사 — 이 저장소에서 반복해서 밟은 패턴을 기계로 잡는다.

왜 있나 (2026-08-14 회고 승격 ⑤):
  「파이프 뒤 grep -q」 함정을 한 세션에서 **열여섯 번** 밟았다. pipefail
  아래서 grep 이 매치 즉시 닫히면 앞 명령이 SIGPIPE 로 죽고, 그 141 이
  판정을 뒤집는다 — 차단이 통째로 사라지는데 에러도 안 난다. 규칙(주석)은
  이미 있었는데도 밟았으므로, 규칙이 아니라 기계가 잡는다.

왜 파이썬인가 (2026-08-14, 이식):
  셸 판(sh)은 인용·플래그 위치를 정규식으로 흉내내다 네 라운드 연속 지적을
  받았다. 파이썬 판은 논리 줄을 토큰화해 인용 안의 예시 문자열, 플래그 순서,
  결합 플래그를 **문법 수준에서** 가른다.

왜 shlex 가 아닌가 (2026-08-14, PR #93):
  shlex 는 어느 모드든 셸과 어긋났다 — posix=True 는 인용을 벗겨 '# value' 를
  주석으로 오인했고(PR #91), posix=False 는 인용 진입을 토큰 시작에서만
  인식해 VAR="… | grep -q …" 의 인용 안 파이프를 실 토큰으로 냈다. 미세조정
  네 번(#89 commenters, #90 인접 구두점, #91 posix, #93 중간 인용) 만에
  접근을 바꾼다(승격 규칙: 같은 데를 세 번 고치면 판정/도구 포기를 검토) —
  아래 tokenize() 는 필요한 셸 규칙(인용·백슬래시·주석·메타문자)만 문자
  단위로 그대로 구현한 ~40줄 스캐너다.

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
import sys

# Windows CP949 콘솔은 출력 문구의 U+2014 를 인코딩하지 못해 성공한 검사까지
# 죽는다(PR #92 P1). 쌍둥이(check-branch-commits·merge-cleanup)와 같은 블록 —
# 문구는 그대로 두고 스트림이 표현 못 하는 글자만 ? 로 바꾼다.
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(errors="replace")
    except AttributeError:
        pass

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


def tokenize(line):
    """셸 인용 규칙대로 논리 줄을 단어·연산자 토큰으로 가른다.

    지켜야 했던 셸 규칙 네 가지 — 전부 shlex 로 밟았던 자리다:
      - 인용은 **단어 어느 위치에서든** 시작한다. VAR="…" 나 --msg='…' 의
        값 속 파이프는 리터럴이다 (claude, PR #93 — posix=False 는 토큰
        시작에서만 인용을 인식해 거짓 차단이 났다)
      - 따옴표는 토큰에 **남긴다.** 벗기면 '# value' 가 주석으로 오인된다
        (codex, PR #91)
      - `#` 는 인용 밖 **단어 시작**에서만 주석이다. `${dir#./}` 의 # 는
        값의 일부다 (codex, PR #89)
      - 메타문자 `| ; & ( )` 는 공백 없이 붙어도 경계다. `$(cmd)|grep` 의
        `)|` 가 한 덩어리로 묶이면 파이프가 사라진다 (claude, PR #90)
    """
    tokens, word = [], []
    quote = None  # 열려 있는 인용부호 — "'" 또는 '"'
    i, n = 0, len(line)
    while i < n:
        c = line[i]
        if quote:
            word.append(c)
            if quote == '"' and c == "\\" and i + 1 < n:
                i += 1
                word.append(line[i])  # \" 가 닫는 따옴표로 읽히지 않게
            elif c == quote:
                quote = None
        elif c == "\\":
            word.append(c)
            if i + 1 < n:
                i += 1
                word.append(line[i])
        elif c in "'\"":
            quote = c
            word.append(c)
        elif c == "#" and not word:
            break
        elif c in "|&;()":
            if word:
                tokens.append("".join(word))
                word = []
            if c in "|&" and i + 1 < n and line[i + 1] == c:
                tokens.append(c + c)  # || 와 && 는 파이프가 아니다
                i += 1
            else:
                tokens.append(c)
        elif c.isspace():
            if word:
                tokens.append("".join(word))
                word = []
        else:
            word.append(c)
        i += 1
    if word:
        # 닫히지 않은 인용 포함 — 남은 것을 단어로 낸다. 여러 줄 문자열의
        # 뒷줄이 코드처럼 보이면 오탐이 날 수 있지만, 거짓 차단은 사람이
        # 보고 거짓 통과는 이력에 남는다.
        tokens.append("".join(word))
    return tokens


def scan_line(line):
    """논리 줄 하나에 「파이프 뒤 quiet grep」이 있으면 참."""
    seg = []
    prev_pipe = False
    for t in tokenize(line):
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
            # 자기 자신(sh 시절 포함)만 뺀다 — 패턴 문자열이 문서로 들어 있다.
            # 접두사로 빼면 이름을 흉내 낸 운영 스크립트(*.legacy.sh 등)까지
            # 검사를 빠져나간다 (codex, PR #93).
            if name in {"check-shell-pitfalls.py", "check-shell-pitfalls.sh"}:
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
