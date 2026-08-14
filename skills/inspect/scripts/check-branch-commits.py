#!/usr/bin/env python3
"""inspect 1·2번의 기계 판정. Phase 5 에서 부른다.

    "${CLAUDE_PLUGIN_ROOT}/skills/inspect/scripts/check-branch-commits.py" [통합브랜치]

체크리스트에 코드 블록으로 두었더니 블록마다 새 셸이라 BASE 가 없었다 —
`..HEAD` 가 `HEAD..HEAD` 로 읽혀 커밋을 하나도 못 세고 조용히 통과했다.
스크립트로 뺐고(PR #49), 2026-08-14 에 sh → 파이썬으로 이식했다.

왜 파이썬인가: sh 판은 SIGPIPE·인용 파싱·실패 삼킴 함정으로 리뷰 스무 라운드를
돌았다. 여기서는 그 부류가 문법 수준에서 없다 — 파이프가 없고, 실패는 예외로
터지고, 인용은 subprocess 인자 리스트라 애초에 안 섞인다.

동작·출력 문구·종료 코드는 sh 판과 같다 — 기존 시험이 그대로 잰다.
"""
import os
import re
import subprocess
import sys
from collections import Counter

FAIL = 0


def bad(msg):
    global FAIL
    print("FAIL — %s" % msg, file=sys.stderr)
    FAIL = 1


def ok(msg):
    print("PASS — %s" % msg)


def die(msg):
    bad(msg)
    sys.exit(1)


def run(args, timeout=None):
    """(exit code, stdout). stderr 는 버린다(sh 판과 같다).

    timeout 이 지나면 **프로세스 그룹째** 죽인다 — `subprocess.run(timeout=)`
    은 부모만 kill 해서 git 이 띄운 ssh 가 남고, 시한 뒤에도 원격을 바꾼다
    (codex, PR #69 — sh 판도 같은 이유로 set -m 을 썼다). start_new_session
    으로 자식을 그룹 리더로 만들고 killpg 로 그룹 전체에 보낸다.
    TERM 을 무시하는 프로세스가 있으니 유예 5초 뒤 KILL 로 올린다.
    """
    import signal
    try:
        p = subprocess.Popen(
            args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
            start_new_session=timeout is not None,
        )
    except FileNotFoundError:
        return 127, ""
    try:
        out, _ = p.communicate(timeout=timeout)
        return p.returncode, out
    except subprocess.TimeoutExpired:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(os.getpgid(p.pid), sig)
            except (ProcessLookupError, PermissionError):
                p.kill()
            try:
                p.communicate(timeout=5)
                break
            except subprocess.TimeoutExpired:
                continue
        return 124, ""

def git(*args, timeout=None):
    return run(["git"] + list(args), timeout=timeout)


def redact(url):
    """진단에 URL 을 실을 때 자격 증명을 가린다 — 토큰이 로그에 남는다 (PR #66)."""
    return re.sub(r"(://)[^@/]*@", r"\1***@", url)


def host_of(url):
    """호스트를 뽑는다. 프로토콜의 **기본 포트는 뗀다** (PR #66) — `ssh://…:22/`
    를 명시하는 구성이 있는데 비교 상대에는 포트가 없어 같은 서버를 다른
    서버로 판정했다. 기본이 아닌 포트는 남긴다 — 사내 미러가 포트로만 갈린다.
    """
    if "://" in url:
        scheme, rest = url.split("://", 1)
        scheme = scheme.lower()
        host = re.sub(r"^[^@]*@", "", rest).split("/", 1)[0]
    else:
        scheme = "ssh"
        host = re.split(r"[:/]", re.sub(r"^[^@]*@", "", url), 1)[0]
    host = host.lower()
    for sch, port in (("ssh", ":22"), ("https", ":443"), ("http", ":80"), ("git", ":9418")):
        if scheme == sch and host.endswith(port):
            host = host[: -len(port)]
    return host


def nwo_of(url):
    """`owner/repo` 로 정규화한다 — 끝 슬래시를 먼저 지운다 (merge-cleanup 과 동일)."""
    s = re.sub(r"^[a-z+]+://", "", url)
    s = re.sub(r"^[^@]*@", "", s)
    s = re.sub(r"^[^:/]*[:/]", "", s)
    s = s.rstrip("/")
    s = re.sub(r"\.git$", "", s)
    parts = s.split("/")
    if len(parts) >= 2:
        return "/".join(parts[-2:]).lower()
    return ""


def owner_of(url):
    """push URL 에서 소유자를 뽑는다 (sh 판의 sed 체인과 같은 결과)."""
    nwo = nwo_of(url)
    return nwo.split("/")[0] if "/" in nwo else ""


def has_remote(name):
    _, out = git("remote")
    return name in out.splitlines()


def git_config(key):
    rc, out = git("config", key)
    return out.strip() if rc == 0 else None


def main():
    base_branch = sys.argv[1] if len(sys.argv) > 1 else ""
    # Phase 6 에서 다시 부를 때만 **그 PR 번호**를 넘긴다. 열린 PR 을 무조건
    # 빼면 얼린 PR 에 커밋을 얹는 것을 못 잡는다.
    phase6_pr = ""
    if len(sys.argv) > 3 and sys.argv[2] == "--phase6":
        phase6_pr = sys.argv[3]

    # detached HEAD 면 밀어 올릴 브랜치가 없다 — inspect 는 커밋을 하나씩
    # 체크아웃해 보므로 실제로 이 상태에 놓인다.
    rc, out = git("symbolic-ref", "-q", "--short", "HEAD")
    if rc != 0:
        print("FAIL — detached HEAD 다. 기능 브랜치로 돌아온다: git switch -", file=sys.stderr)
        sys.exit(1)
    br = out.strip()

    # ── 1. 브랜치 전략 ──────────────────────────────────────────
    if not base_branch:
        rc, out = git("symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD")
        base_branch = out.strip().replace("origin/", "", 1) if rc == 0 else ""
    if not base_branch:
        die("통합 브랜치를 못 정했다. 인자로 넘긴다")

    # 흔한 이름 셋만 박아두면 프로젝트가 정한 `release` 같은 이름을 놓친다.
    # **인자로 받은 통합 브랜치 자체**도 거부 대상이다.
    if br in ("main", "master", "develop"):
        bad("보호 브랜치(%s)에서 작업하고 있다" % br)
    if br == base_branch:
        bad("통합 브랜치(%s)에서 작업하고 있다" % br)

    # head 와 base 이름이 ASCII 인가 — claude-code-action 이 base 의 비ASCII 를 거부한다.
    if any(not (0x20 <= ord(c) <= 0x7E) for c in br + base_branch):
        bad("브랜치 이름에 비ASCII 가 있다 — base 면 claude 리뷰 잡이 죽는다")
    else:
        ok("브랜치 이름이 ASCII 다")

    # push 대상 원격. 실패를 삼키지 않는다 — 못 구하면 소유자 대조가 빈 값으로
    # 돌아 「한 번도 안 쓴 브랜치」로 오판한다.
    head_remote = (
        git_config("branch.%s.pushRemote" % br)
        or git_config("remote.pushDefault")
        or git_config("branch.%s.remote" % br)
        or "origin"
    )

    # 원격이 없으면 재사용 검사를 **건너뛴다** — 판정 근거가 없는 것을 실패로
    # 내면 로컬 전용 저장소에서 Phase 5 가 늘 막힌다. 있는데 못 읽는 것은 다르다.
    head_owner = ""
    head_owners = []
    if has_remote(head_remote):
        # push URL 이 여럿일 수 있다 — 첫 것만 보면 두 번째 fork 의 옛 PR 이
        # 안 걸리는데 push 는 그쪽에도 올라간다 (codex, PR #67).
        rc, out = git("remote", "get-url", "--push", "--all", head_remote)
        if rc != 0:
            die("원격 '%s' 의 push URL 을 못 구했다. 재사용 검사를 못 한다" % head_remote)
        head_urls = [u for u in out.splitlines() if u]
        for hu in head_urls:
            o = owner_of(hu)
            if not o:
                die("원격 URL 에서 소유자를 못 뽑았다: %s" % redact(hu))
            if o not in head_owners:
                head_owners.append(o)
        head_owner = owner_of(head_urls[0]) if head_urls else ""
    else:
        print("  (원격이 없다 — 재사용 검사를 건너뛴다)", file=sys.stderr)

    # 이 브랜치로 PR 이 열렸던 적이 있나. fork 면 parent 를 짚는다.
    # gh 에는 요청 타임아웃 옵션이 없다 — timeout= 으로 직접 잰다.
    upstream = upstream_url = is_fork = ""
    if head_owner:
        # 한 호출로 받는다 — 두 번 부르면 두 번째만 실패했을 때 호스트 대조가
        # 조용히 꺼진다 (codex, PR #64). -q(@tsv) 계약은 sh 판·시험과 같다.
        rc, out = run(
            ["gh", "repo", "view", "--json", "parent,nameWithOwner,url",
             "-q", '[(.parent.nameWithOwner // ""), .nameWithOwner, (.parent.url // .url)] | @tsv'],
            timeout=30,
        )
        if rc != 0:
            die("gh 로 저장소를 못 읽었다(인증·네트워크). 재사용 검사를 통과로 두지 않는다")
        first = out.splitlines()[0] if out.splitlines() else ""
        cols = first.split("\t") + ["", "", ""]
        is_fork, upstream_url = cols[0], cols[2]
        upstream = cols[0] if cols[0] else cols[1]

    if head_owner and upstream:
        # 뺄 번호는 Phase 6 에서 넘긴 그 PR 하나다. 숫자가 아니면 -1.
        skip_pr = phase6_pr if re.fullmatch(r"-?[0-9]+", phase6_pr or "") else "-1"

        # 호스트를 붙인다 — 이름만 주면 api.github.com 으로 가서 사내 GitHub
        # 에서는 조회가 실패하거나 동명 저장소 이력을 오판한다 (codex, PR #66).
        up_host = host_of(upstream_url) if upstream_url else ""
        repo_arg = ("%s/%s" % (up_host, upstream)) if up_host else upstream
        # 소유자 **목록 전체**로 거른다 — 모아 놓고 첫 것만 쓴 적이 있다
        # (claude, PR #68). jq 필터는 시험의 가짜 gh 와 같은 계약이다.
        owners_blob = "|" + "|".join(o.lower() for o in head_owners) + "|"
        jq = (
            '[.[] | select(("|" + ((.headRepositoryOwner.login // "") | ascii_downcase) + "|")\n'
            '             | inside("%s"))\n'
            "            | select(.number != %s)] | .[0] // empty" % (owners_blob, skip_pr)
        )
        rc, out = run(
            ["gh", "pr", "list", "--repo", repo_arg, "--state", "all",
             "--head", br, "--limit", "1000",
             "--json", "number,state,headRepositoryOwner", "-q", jq],
            timeout=30,
        )
        if rc != 0:
            bad("PR 이력을 못 읽었다(네트워크·인증·시한). 재사용 검사를 통과로 두지 않는다")
            sys.exit(1)
        prior = out.strip()
        if prior:
            bad("이 브랜치로 이미 PR 이 열렸다: %s — 통합 브랜치에서 새로 판다" % prior)
        elif phase6_pr:
            ok("이 브랜치의 PR 은 지금 처리 중인 #%s 하나다" % phase6_pr)
        else:
            ok("이 브랜치로 열린 PR 이 없다")
    else:
        print("  (gh 로 저장소를 못 읽었다 — 재사용 검사를 건너뛴다)", file=sys.stderr)

    # ── 2. 커밋 단위 ────────────────────────────────────────────
    # BASE 원격은 이름이 아니라 **확인된 upstream 과 URL 대조**로 고른다 —
    # `upstream` 이라는 이름이 다른 미러를 가리키면 엉뚱한 merge-base 로
    # 커밋을 센다 (codex, PR #62·#63).
    base_remote = ""
    if upstream:
        want_up = upstream.lower()
        want_host = host_of(upstream_url) if upstream_url else ""
        _, remotes = git("remote")
        for rmt in remotes.split():
            rc, u = git("remote", "get-url", rmt)
            if rc != 0:
                continue
            u = u.strip()
            if nwo_of(u) != want_up:
                continue
            # 한쪽 호스트가 비면(로컬 경로 원격) 대조할 것이 없다.
            if want_host and host_of(u) != want_host:
                continue
            base_remote = rmt
            break
    if not base_remote:
        # fork 인데 upstream 원격이 없으면 폴백하지 않는다 — fork 의 origin 은
        # 대개 낡아서 남의 커밋까지 내 것으로 세어진다 (codex, PR #65).
        if is_fork:
            bad("upstream %s 을 가리키는 원격이 없다.\n"
                "       추가한 뒤 다시 돌린다:  git remote add upstream <그 저장소 URL>" % upstream)
            sys.exit(1)
        base_remote = git_config("branch.%s.remote" % base_branch) or "origin"

    # ref 가 있어도 가져온다 — 낡은 것으로 재면 남의 커밋이 내 것으로 세어진다.
    if has_remote(base_remote):
        # refspec 을 명시한다 — single-branch 클론은 fetch refspec 이 좁아
        # 추적 ref 를 안 만든다. --no-write-fetch-head 로 사용자의 FETCH_HEAD
        # 를 건드리지 않는다.
        rc, _ = git("fetch", "--no-tags", "--no-write-fetch-head", base_remote,
                    "+refs/heads/%s:refs/remotes/%s/%s" % (base_branch, base_remote, base_branch),
                    timeout=30)
        if rc != 0:
            die("%s/%s 를 갱신하지 못했다(네트워크·인증). 낡은 ref 로 판정하지 않는다"
                % (base_remote, base_branch))
        rc, _ = git("rev-parse", "--verify", "-q", "%s/%s" % (base_remote, base_branch))
        if rc != 0:
            die("%s/%s 를 못 찾았다. fetch 하거나 통합 브랜치를 확인한다" % (base_remote, base_branch))
        base_ref = "%s/%s" % (base_remote, base_branch)
    else:
        rc, _ = git("rev-parse", "--verify", "-q", base_branch)
        if rc != 0:
            die("통합 브랜치 '%s' 가 로컬에도 없다" % base_branch)
        base_ref = base_branch

    rc, out = git("merge-base", "HEAD", base_ref)
    if rc != 0:
        die("merge-base 를 못 구했다")
    base = out.strip()

    rc, out = git("log", "--oneline", "%s..HEAD" % base)
    oneline = [l for l in out.splitlines() if l]
    print("커밋 %d개 (%s..HEAD)" % (len(oneline), base[:8]))
    for l in oneline:
        print(l)

    check_commit_shapes(base)

    # 같은 파일을 세 번 이상 건드린 커밋들 — 한 자리를 여러 번 고쳤다는 신호.
    print("\n같은 파일을 반복해 건드린 횟수:")
    _, shas = git("log", "--format=%H", "%s..HEAD" % base)
    counts = Counter()
    for c in shas.split():
        _, names = git("show", "--name-only", "--format=", c)
        counts.update(n for n in names.splitlines() if n)
    for name, cnt in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
        if cnt >= 3:
            print("  %d회  %s" % (cnt, name))

    print("\n하위 기능 수를 세어 커밋 수(%d)와 비교한다. 많으면 접는다(규칙 2)." % len(oneline))
    sys.exit(FAIL)


# 구현만·테스트만 있는 커밋 — 갈라진 것이다(규칙 2). 경로 요소·접미사로만
# 잡는다. 부분문자열로 보면 `ContestService.java` 가 테스트로 잡힌다.
TESTPAT = re.compile(
    r"(^|/)(test|tests|spec|specs|__tests__)/"
    r"|(^|/)(test|spec)[._-][^/]*$"
    r"|(^|/)[^/]*([._-](test|spec)|Test|Tests|Spec|IT)\.[A-Za-z]+$"
)
# 문서 판정 — `LICENSE` 류는 끝 경계, `docs/` 는 최상위만 (PR #59·#62·#71).
DOCPAT = re.compile(
    r"\.(md|markdown|rst|adoc)$"
    r"|^(docs|doc)/"
    r"|(^|/)(LICENSE|CHANGELOG|NOTICE|README|AUTHORS|CONTRIBUTING)([._-][A-Za-z0-9]+)?$"
)
# 파일 안에 테스트가 함께 있는 관례. `it\(` 는 경계를 못박는다 — 안 그러면
# `exit(`·`commit(` 에 걸린다 (claude, PR #55).
INLINE_TEST = re.compile(
    r"#\[cfg\(test\)\]|func Test[A-Z]|@Test|def test_|(^|[^A-Za-z0-9_.])(describe|it|test)\("
)


def show_names(sha, *extra):
    """커밋의 변경 경로. 실패를 빈 커밋으로 읽지 않는다 (codex, PR #72) —
    부분 클론·객체 손상이면 거짓 PASS 가 된다."""
    rc, out = git("show", "--name-only", "--format=", "-m", "--first-parent", *extra, sha)
    if rc != 0:
        die("커밋 %s 의 변경 목록을 못 읽었다(객체 손상·부분 클론)" % sha[:8])
    return [l for l in out.splitlines() if l]


def check_commit_shapes(base):
    """커밋 하나하나를 「구현+테스트가 함께 있나」로 분류한다.

    제목으로 건너뛰지 않는다 — `chore:` 접두사 하나로 검사가 무력해졌다
    (codex, PR #67). 예외는 바뀐 경로로만 판정한다.
    """
    split, colocated = [], []
    rc, out = git("log", "--format=%H%x00%s", "%s..HEAD" % base)
    for line in out.splitlines():
        if not line:
            continue
        sha, _, subject = line.partition("\x00")

        # 두 벌로 나눈다 — 삭제 포함(분류용)과 삭제 제외(증거용). 한 벌로 두면
        # 테스트를 지운 커밋이 통과하거나(PR #58) 테스트만 지운 커밋이 검사를
        # 통째로 건너뛴다(PR #59). merge 커밋은 첫 부모와의 diff 로 (PR #68).
        files_all = show_names(sha)
        files = show_names(sha, "--diff-filter=d")
        if not files_all:
            continue

        # 문서 예외는 경로로 본다 — 제목만 보면 README 하나 고친 커밋이 FAIL 이었다.
        if not [f for f in files_all if not DOCPAT.search(f)]:
            continue

        has_test = sum(1 for f in files if TESTPAT.search(f))
        del_only = show_names(sha, "--diff-filter=D")
        del_test = sum(1 for f in del_only if TESTPAT.search(f))
        # 경로가 테스트로 안 보여도 **지워진 파일 안**의 인라인 테스트는 함께
        # 지운 것이다 (codex, PR #66).
        if del_test == 0:
            for df in del_only:
                rc, blob = git("show", "%s^:%s" % (sha, df))
                if rc == 0 and INLINE_TEST.search(blob):
                    del_test = 1
                    break
        del_src = sum(1 for f in del_only if not TESTPAT.search(f) and not DOCPAT.search(f))
        has_src = sum(1 for f in files_all if not TESTPAT.search(f) and not DOCPAT.search(f))

        # 구현·테스트를 **함께 지운** 것은 정상 — 다만 커밋 전체를 면제하면
        # 딴 파일의 무테스트 수정까지 통과한다 (codex, PR #69·#70).
        if del_test > 0 and del_src > 0:
            has_src = max(0, has_src - del_src)
            if has_src == 0 and has_test == 0:
                continue
        if has_test > 0 and has_src > 0:
            continue

        # 구현 파일 안에 테스트를 두는 관례(Rust·Go·JS) — **판정하지 않는다.**
        # 세 번 고쳤고 세 번 뚫렸다(PR #56·#59·#69). 목록으로 사람에게 넘긴다.
        if has_test == 0 and has_src > 0:
            inline = False
            for f in files:
                rc, blob = git("show", "%s:%s" % (sha, f))
                if rc == 0 and INLINE_TEST.search(blob):
                    inline = True
                    break
                # 지워진 표식도 colocated 신호다 — 함께 걷어낸 커밋은 커밋 뒤
                # 파일에 표식이 안 남는다.
                rc, diff = git("show", "--format=", "-U0", sha, "--", f)
                if rc == 0 and any(
                    l.startswith("-") and INLINE_TEST.search(l) for l in diff.splitlines()
                ):
                    inline = True
                    break
            if inline:
                colocated.append("  %s %s" % (sha[:8], subject))
                continue

        split.append("  갈라진 커밋: %s %s" % (sha[:8], subject))

    if split:
        for l in split:
            print(l, file=sys.stderr)
        bad("구현만·테스트만 있는 커밋이 있다 — 하나로 합친다(규칙 2)")

    # FAIL 이 아니다 — 기계가 가를 수 없는 자리라 사람에게 넘긴다.
    if colocated:
        print("  구현 파일 안에 테스트를 둔 커밋 — 눈으로 확인한다:", file=sys.stderr)
        for l in colocated:
            print(l, file=sys.stderr)
        print("    (구현과 테스트가 같은 커밋에 들어 있는지 본다. 규칙 2)", file=sys.stderr)


if __name__ == "__main__":
    main()
