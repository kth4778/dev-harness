#!/usr/bin/env python3
"""PR 을 머지하고 브랜치를 정리한다. Phase 6 에서 부른다.

    "${CLAUDE_PLUGIN_ROOT}/skills/pr/scripts/merge-cleanup.py" <PR번호>

문서 안 코드 블록 → sh 스크립트 → 파이썬(2026-08-14)의 세 번째 모습이다.
sh 판은 SIGPIPE·인용·실패 삼킴으로 리뷰 스무 라운드를 돌았다 — 그 라운드들이
남긴 판정 순서와 안전장치는 전부 보존하고, 셸 함정 부류만 걷어낸다:
파이프가 없고, 실패는 예외로 터지고, 프로세스 그룹 종료는 표준 기능이다.

동작·출력 문구·종료 코드는 sh 판과 같다 — hooks/tests/cleanup.sh 가 그대로 잰다.
"""
import os
import re
import subprocess
import sys

# Windows 콘솔(CP949)은 이 스크립트의 출력 문구에 든 — (U+2014) 를 인코딩하지
# 못해, **성공한 검사가 출력 단계에서 죽는다** (codex, PR #92 — wiki-sync 가
# 문서화한 바로 그 환경이다). 문구를 바꾸는 대신 스트림을 관대하게 만든다.
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(errors="replace")
    except AttributeError:
        pass
import time


def die(msg):
    print("차단됨 — %s" % msg, file=sys.stderr)
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
            # errors="replace" — 이 헬퍼로 커밋의 **blob 자체**를 읽는 자리가
            # 있다(인라인 테스트 검사). 바이너리(이미지·jar)를 strict 로 읽으면
            # UnicodeDecodeError 로 Phase 5 가 트레이스백과 함께 죽는다 — sh 판의
            # grep 은 안 죽었으니 이식 회귀였다 (codex·claude, PR #89).
            args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, errors="replace",
            start_new_session=timeout is not None,
        )
    except FileNotFoundError:
        return 127, ""
    try:
        out, _ = p.communicate(timeout=timeout)
        return p.returncode, out
    except subprocess.TimeoutExpired:
        # Windows 에는 SIGKILL·killpg·getpgid 가 없다 — 그대로 부르면 시한
        # 처리 자체가 AttributeError 로 죽어 자식이 산 채로 남는다 (PR #91).
        # 프로세스 하나만 죽이는 것도 부족하다 — 파괴적 명령(push --delete)이
        # 띄운 ssh 가 살아남아 **시한 뒤에 삭제를 마칠 수 있다** (codex, PR #92).
        # Windows 는 taskkill /T 로 **트리 전체**를 끝낸다.
        if not hasattr(os, "killpg"):
            subprocess.run(["taskkill", "/PID", str(p.pid), "/T", "/F"],
                           capture_output=True)
            try:
                p.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
            return 124, ""
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
        else:
            p.kill()
            try:
                p.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        return 124, ""

def git(*args, timeout=None):
    return run(["git"] + list(args), timeout=timeout)


def git_config(key):
    rc, out = git("config", key)
    return out.strip() if rc == 0 else None


def redact(url):
    """진단에 URL 을 실을 때 자격 증명을 가린다 — 토큰이 로그에 남는다 (PR #65)."""
    return re.sub(r"(://)[^@/]*@", r"\1***@", url)


def url_nwo(url):
    """`owner/repo` 로 정규화해 **정확히** 비교한다 — 부분문자열로 보면
    `me/work` 가 `me/work-backup` 에 들어맞아 엉뚱한 원격에서 지운다."""
    s = re.sub(r"^[a-z+]+://", "", url)
    s = re.sub(r"^[^@]*@", "", s)
    s = re.sub(r"^[^:/]*[:/]", "", s)
    s = s.rstrip("/")
    s = re.sub(r"\.git$", "", s)
    parts = s.split("/")
    return "/".join(parts[-2:]).lower() if len(parts) >= 2 else ""


def url_host(url):
    """호스트를 뽑는다 — `owner/repo` 만 맞추면 github.com 과 사내 미러가 같아
    보여 다른 서버의 동명 브랜치를 지운다 (PR #56). 기본 포트만 떼고(PR #66)
    사내 포트는 남긴다(PR #59) — 미러가 포트로만 갈리는 경우를 가려야 한다."""
    if "://" in url:
        scheme, rest = url.split("://", 1)
        scheme = scheme.lower()
        host = re.sub(r"^[^@]*@", "", rest).split("/", 1)[0]
    else:
        scheme = "ssh"  # scp 형태(host:path) — `:` 뒤는 경로라 포트를 쓸 수 없다
        host = re.split(r"[:/]", re.sub(r"^[^@]*@", "", url), 1)[0]
    host = host.lower()
    for sch, port in (("ssh", ":22"), ("https", ":443"), ("http", ":80"), ("git", ":9418")):
        if scheme == sch and host.endswith(port):
            host = host[: -len(port)]
    return host


def main():
    if len(sys.argv) < 2 or not sys.argv[1]:
        print("PR 번호를 넘겨라", file=sys.stderr)
        sys.exit(1)
    pr = sys.argv[1]

    # **base 저장소를 먼저 확정한다.** `gh pr view` 는 현재 폴더의 저장소를
    # 보는데, fork 에서 base 원격 이름이 `upstream` 이 아니면 fork 의 같은
    # 번호를 조회해 Phase 6 이 통째로 막힌다 (codex, PR #73).
    rc, out = run(
        ["gh", "repo", "view", "--json", "parent,nameWithOwner",
         "-q", '[(.parent.nameWithOwner // ""), .nameWithOwner] | map(select(. != "")) | .[0]'],
        timeout=30,
    )
    pr_repo_arg = out.strip() if rc == 0 else ""

    def gh_json(field, jq):
        """조회 실패를 삼키지 않는다 — 성공 여부와 값을 함께 돌려준다."""
        args = ["gh", "pr", "view", pr]
        if pr_repo_arg:
            args += ["-R", pr_repo_arg]
        args += ["--json", field, "-q", jq]
        rc, out = run(args, timeout=30)
        return (rc == 0), out.strip()

    # ── PR 이 정말 이 브랜치의 것인지 먼저 확인한다 ─────────────
    # 번호를 잘못 넣으면 아무 상관 없는 브랜치를 원격까지 지운다.
    _, out = git("rev-parse", "--abbrev-ref", "HEAD")
    br = out.strip()
    okv, pr_head = gh_json("headRefName", ".headRefName")
    if not okv:
        die("PR #%s 을 못 읽었다" % pr)

    # PR URL 로 저장소·호스트를 확정하고 이후 API 를 전부 묶는다 (PR #59·#61).
    okv, pr_url = gh_json("url", ".url")
    if not okv:
        die("PR #%s 의 URL 을 못 읽었다" % pr)
    # `pull/<번호>` 를 떼고 **push URL 과 같은 함수**로 푼다 — 따로 짠 정규식은
    # 로컬 경로 URL 에서 다른 답을 내 비교가 어긋났다 (codex, PR #72).
    pr_baseurl = re.sub(r"/pull/[0-9]+.*$", "", pr_url)
    api_nwo = url_nwo(pr_baseurl)
    api_host = url_host(pr_baseurl)
    if "/" not in api_nwo:
        die("PR URL 에서 저장소를 못 뽑았다: %s" % pr_url)
    if pr_head != br:
        die("PR #%s 의 head 는 '%s' 인데 지금은 '%s' 에 있다" % (pr, pr_head, br))

    # base 도 PR 에서 가져온다 — origin/HEAD 를 믿으면 develop 저장소에서
    # 엉뚱한 브랜치로 옮겨 놓고 정리했다고 보고한다.
    okv, base = gh_json("baseRefName", ".baseRefName")
    if not okv:
        die("PR #%s 의 base 를 못 읽었다" % pr)

    # PR head 와 로컬 HEAD 가 같은지 — 다르면 push 안 한 커밋을 날린다.
    okv, pr_oid = gh_json("headRefOid", ".headRefOid")
    if not okv:
        die("PR #%s 의 head 커밋을 못 읽었다" % pr)
    _, out = git("rev-parse", "HEAD")
    local_oid = out.strip()

    # head **저장소**도 대조한다 — 다른 fork 의 동명 브랜치가 같은 커밋을
    # 가리키면 이름도 SHA 도 같아서 통과하고, 내 fork 에서 브랜치를 지운다.
    okv, pr_owner = gh_json("headRepositoryOwner", ".headRepositoryOwner.login")
    if not okv:
        die("PR #%s 의 head 저장소 소유자를 못 읽었다" % pr)
    okv, pr_repo = gh_json("headRepository", ".headRepository.name")
    if not okv:
        die("PR #%s 의 head 저장소 이름을 못 읽었다" % pr)
    if pr_oid != local_oid:
        die("PR #%s 의 head 는 %s 인데 로컬 HEAD 는 %s 다.\n"
            "       push 안 한 커밋이 있거나 다른 저장소의 동명 브랜치다"
            % (pr, pr_oid[:8], local_oid[:8]))

    # 원격 상태를 바꾸기 **전에** 작업 트리가 깨끗한지 본다 (codex, PR #67).
    # 조회 실패도 잡는다 — 실패를 「깨끗함」으로 읽으면 전환에서 터진다 (PR #68).
    dirty = worktree_dirty_count()
    if dirty is None:
        die("작업 트리 상태를 못 읽었다(인덱스 손상·서브모듈).\n"
            "       원격을 건드리기 전에 확인한다:  git status")
    if dirty:
        die("작업 트리에 커밋되지 않은 변경이 %d 개 있다.\n"
            "       머지하면 브랜치를 옮기지 못해 정리가 중간에 멈춘다 — 먼저 정리한다:\n"
            "         git status --short" % dirty)

    # ── 봇 둘이 각각 **현재 head** 를 봤는지 확인한다 ───────────
    # 증거는 세 채널로 온다 — 리뷰(SHA 있음)·코멘트·반응(SHA 없음). PR #33 은
    # codex 가 반응만, claude 가 코멘트만 남겼다 — 리뷰 목록만 보면 영영 머지
    # 불가였다. SHA 없는 채널은 현재 head 를 본 것인지 기계가 알 수 없으므로
    # 자동 통과시키지 않는다.
    # 봇 로그인은 **정확히** 대조하고(느슨하면 아무 계정이 통과시킨다),
    # 목록은 환경변수로 못 바꾼다 — 규칙 7 이 딱 2 개를 요구한다 (PR #59).
    bots = ["chatgpt-codex-connector[bot]", "claude[bot]"]

    def gh_api(path, jq):
        args = ["gh", "api"]
        if api_host:
            args += ["--hostname", api_host]
        args += ["--paginate", path, "-q", jq]
        return run(args, timeout=30)

    def seen_bot_sha(bot):
        """SHA 있는 증거(리뷰·인라인 코멘트)만 자동으로 받는다."""
        for path in ("repos/%s/pulls/%s/reviews" % (api_nwo, pr),
                     "repos/%s/pulls/%s/comments" % (api_nwo, pr)):
            _, out = gh_api(path, '.[] | select(.user.login == "%s") | .commit_id' % bot)
            if pr_oid in out.split():
                return True
        return False

    def seen_bot_shaless(bot):
        """이슈 코멘트·👍 반응. 반응은 `+1` 만 — `eyes` 는 검토 시작 표시라
        완료로 읽으면 안 본 코드가 머지된다."""
        _, out = gh_api("repos/%s/issues/%s/comments" % (api_nwo, pr),
                        '.[] | select(.user.login == "%s") | .id' % bot)
        if out.strip():
            return True
        _, out = gh_api("repos/%s/issues/%s/reactions" % (api_nwo, pr),
                        '.[] | select(.user.login == "%s" and .content == "+1") | .id' % bot)
        return bool(out.strip())

    missing, shaless = [], []
    for bot in bots:
        if seen_bot_sha(bot):
            continue
        (shaless if seen_bot_shaless(bot) else missing).append(bot)
    if missing:
        die("봇이 현재 head(%s)를 본 증거가 없다: %s\n"
            "       리뷰 뒤에 push 됐거나 아직 안 돌았다 — 그 커밋은 아무도 안 봤다.\n"
            "       새 브랜치로 다시 올린다(규칙 7)" % (pr_oid[:8], " ".join(missing)))
    # 값이 **정확히 1** 일 때만 연다 — `=0`·`=false` 같은 끄려는 값이 우회를
    # 열면 안 된다 (codex, PR #70).
    if shaless and os.environ.get("CLEANUP_ALLOW_SHALESS", "") != "1":
        die("봇 증거가 SHA 없는 채널로만 왔다: %s\n"
            "       codex 는 지적이 없으면 👍 만, claude 는 --comment 로 돌면 코멘트만 남긴다.\n"
            "       그것이 **현재 head** 를 본 것인지 기계가 확인할 수 없다.\n"
            "       눈으로 확인한 뒤 다시 부른다:  CLEANUP_ALLOW_SHALESS=1 <이 스크립트> %s"
            % (" ".join(shaless), pr))
    reviewed = pr_oid

    # head 를 올린 원격 — 머지 **전에** 잡아둔다. 정리가 브랜치 설정을 지우면
    # 못 구한다. push URL 이 여럿이면 **전부** 검증한다 (codex, PR #64) —
    # 첫 것만 검증하고 이름으로 지우면 검증 안 한 미러에서도 지워진다.
    head_remote = (
        git_config("branch.%s.pushRemote" % br)
        or git_config("remote.pushDefault")
        or git_config("branch.%s.remote" % br)
        or "origin"
    )
    rc, out = git("remote", "get-url", "--push", "--all", head_remote)
    if rc != 0:
        die("원격 '%s' 의 push URL 을 못 구했다" % head_remote)
    head_urls = [u for u in out.splitlines() if u]
    head_url = head_urls[0] if head_urls else ""

    my_nwo = url_nwo(head_url)
    my_host = url_host(head_url)
    pr_nwo = ("%s/%s" % (pr_owner, pr_repo)).lower()
    # 대조용 호스트는 push URL 과 **같은 규칙**으로 정규화한다 (PR #60·#67).
    # gh --hostname 에 넘기는 api_host 는 원형 그대로 둔다.
    gh_host = url_host(pr_url)
    if my_nwo != pr_nwo:
        die("PR #%s 의 head 는 %s 인데 내 push 대상은 %s(%s) 다\n"
            "       — 다른 저장소의 동명 브랜치다"
            % (pr, pr_nwo, my_nwo or "?", redact(head_url)))
    # PR 에는 호스트가 있는데 push 대상에는 없다 = 로컬 경로 원격이다 —
    # 같은 이름의 **딴 저장소**일 수 있고 확인할 방법이 없다 (codex, PR #72).
    if gh_host and not my_host:
        die("PR 은 %s 의 것인데 push 대상은 호스트가 없는 경로다(%s).\n"
            "       같은 이름이어도 다른 저장소일 수 있다 — 지우지 않는다"
            % (gh_host, redact(head_url)))
    if gh_host and my_host and my_host != gh_host:
        die("PR 은 %s 의 것인데 내 push 대상은 %s 다\n"
            "       — 같은 이름이지만 다른 서버다. 지우지 않는다" % (gh_host, my_host))
    # 나머지 push URL 도 같은 잣대 — 하나라도 어긋나면 아무것도 지우지 않는다.
    for u in head_urls[1:]:
        un, uh = url_nwo(u), url_host(u)
        if un != pr_nwo:
            die("원격 '%s' 의 push URL 중 %s 가 %s 가 아니다(%s).\n"
                "       이 이름으로 지우면 그쪽에서도 지워진다 — 멈춘다"
                % (head_remote, redact(u), pr_nwo, un))
        if gh_host and not uh:
            die("원격 '%s' 의 push URL 중 %s 는 호스트가 없는 경로다 — 멈춘다"
                % (head_remote, redact(u)))
        if gh_host and uh and uh != gh_host:
            die("원격 '%s' 의 push URL 중 %s 가 다른 서버(%s)다 — 멈춘다"
                % (head_remote, redact(u), uh))

    # base 원격도 **PR 이 향한 저장소**에서 정한다 — 로컬 설정만 보면 fork 의
    # 낡은 base 를 당긴다. PR 은 base 저장소에 사니 API_NWO 가 곧 base 다.
    base_nwo = api_nwo
    base_remote = ""
    want = base_nwo.lower()
    _, remotes = git("remote")
    for rmt in remotes.split():
        rc, u = git("remote", "get-url", rmt)
        if rc != 0:
            continue
        u = u.strip()
        # 호스트도 본다 — NWO 만 맞추면 알파벳상 앞선 미러가 먼저 잡힌다 (PR #59).
        if url_nwo(u) == want and url_host(u) == my_host:
            base_remote = rmt
            break
    if not base_remote:
        if base_nwo:
            # 폴백하면 fork 의 낡은 base 를 당긴다 — 멈추고 원격을 붙이라고 한다.
            die("PR 의 base 저장소 %s 를 가리키는 원격이 없다.\n"
                "       추가한 뒤 다시 부른다:  git remote add upstream https://%s/%s.git"
                % (base_nwo, api_host, base_nwo))
        base_remote = git_config("branch.%s.remote" % base) or "origin"

    # ── 머지 ────────────────────────────────────────────────────
    # 허용 전략은 **base 저장소** 설정에서 읽고(PR #56), 조회 실패를 「셋 다
    # 허용」으로 읽지 않는다(PR #63). 기본은 --merge(규칙 2 — 커밋 단위를
    # 남긴다), 꺼져 있으면 rebase 먼저(PR #62) — squash 는 이력을 접는다.
    repo_arg = ("%s/%s" % (api_host, base_nwo)) if api_host else base_nwo
    rc, out = run(
        ["gh", "repo", "view", repo_arg,
         "--json", "mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed",
         "-q", '"\\(.mergeCommitAllowed) \\(.squashMergeAllowed) \\(.rebaseMergeAllowed)"'],
        timeout=30,
    )
    if rc != 0:
        die("저장소의 머지 설정을 못 읽었다(권한·네트워크). 어느 전략이 열렸는지 모르는 채로\n"
            "       머지하지 않는다")
    parts = out.split()
    if len(parts) < 3:
        die("머지 설정 응답이 비었다. 정리하지 않는다")
    m_ok, s_ok, r_ok = parts[0] == "true", parts[1] == "true", parts[2] == "true"
    strat = "--merge"
    if not m_ok:
        if r_ok:
            strat = "--rebase"
        elif s_ok:
            strat = "--squash"
        else:
            die("이 저장소는 merge·squash·rebase 를 다 껐다. 설정을 확인한다")
        print("  merge commit 이 꺼져 있다 — %s 로 머지한다" % strat, file=sys.stderr)

    # **`--delete-branch` 를 쓰지 않는다** — 머지 즉시 지워서 아래 안전장치가
    # 통째로 우회된다 (PR #57). 삭제는 전부 검증된 절차가 한다.
    # base 브랜치 보호(선형 이력)가 특정 전략만 거부할 수 있다 — 거부되면
    # 허용된 다른 전략으로 한 번 더 (PR #69).
    def try_merge(s):
        rc, _ = run(
            ["gh", "pr", "merge", pr, "-R",
             ("%s/%s" % (api_host, api_nwo)) if api_host else api_nwo,
             s, "--match-head-commit", reviewed],
            timeout=60,
        )
        return rc == 0

    if not try_merge(strat):
        merged_ok = False
        for alt, allowed in (("--rebase", r_ok), ("--squash", s_ok), ("--merge", m_ok)):
            if alt == strat or not allowed:
                continue
            print("  %s 가 거부됐다(브랜치 보호로 보인다). %s 로 다시 넣는다"
                  % (strat, alt), file=sys.stderr)
            if try_merge(alt):
                merged_ok, strat = True, alt
                break
        if not merged_ok:
            die("머지 요청이 실패했다. 인증·권한·체크·브랜치 보호 규칙, 그리고\n"
                "       리뷰 뒤 push 가 있었는지 확인한다")

    # ── 머지가 **실제로** 끝났는지 본다 ─────────────────────────
    # 명령이 성공해도 큐에 넣기만 했을 수 있다 — 아니면 열린 PR 의 브랜치를 지운다.
    deadline = time.time() + int(os.environ.get("CLEANUP_WAIT_SEC", "1200"))
    poll = float(os.environ.get("CLEANUP_POLL_SEC", "20"))
    while True:
        okv, st = gh_json("state", ".state")
        if not okv:
            die("PR 상태를 못 읽었다. 정리하지 않는다")
        if st in ("MERGED", "CLOSED") or time.time() >= deadline:
            break
        time.sleep(poll)
    if st != "MERGED":
        die("머지가 안 끝났다(%s). 큐와 체크를 확인한다" % st)

    # ── 정리 ────────────────────────────────────────────────────
    # 지울 브랜치에서 먼저 나온다. base 를 다른 worktree 가 쓰면 detach 로
    # (PR #60), 로컬에 base 가 없으면(single-branch clone) 만들어 옮긴다 (PR #70).
    base_refspec = "refs/heads/%s:refs/remotes/%s/%s" % (base, base_remote, base)
    rc, _ = git("switch", base)
    if rc == 0:
        # `git pull` 을 쓰지 않는다 — --no-write-fetch-head 가 없어 사용자의
        # FETCH_HEAD 를 덮어쓴다 (PR #63). fetch 와 fast-forward 로 나눈다.
        rc, _ = git("fetch", "--no-write-fetch-head", base_remote, base_refspec, timeout=60)
        if rc == 0:
            rc, _ = git("merge", "--ff-only", "refs/remotes/%s/%s" % (base_remote, base))
            if rc != 0:
                print("  fast-forward 를 못 했다(로컬이 갈렸다). 나중에 본다", file=sys.stderr)
        else:
            print("  fetch 를 못 했다(나중에)", file=sys.stderr)
    else:
        rc, _ = git("show-ref", "--verify", "-q", "refs/heads/%s" % base)
        if rc == 0:
            # 로컬 base 는 있는데 못 옮겼다 = 다른 worktree 가 점유하고 있다.
            rc, _ = git("switch", "--detach")
            if rc != 0:
                die("%s 로도 detach 로도 못 옮겼다. 워킹트리를 정리하고 다시 부른다" % base)
            rc, _ = git("fetch", "--no-write-fetch-head", base_remote, base_refspec, timeout=60)
            if rc != 0:
                print("  fetch 를 못 했다(나중에)", file=sys.stderr)
            print("  %s 는 다른 worktree 가 쓰고 있다 — detach 로 나왔다. 그 쪽에서 pull 한다"
                  % base, file=sys.stderr)
        else:
            rc, _ = git("fetch", "--no-write-fetch-head", base_remote, base_refspec, timeout=60)
            if rc != 0:
                die("%s 를 가져오지 못했다. 로컬에 그 브랜치가 없어 옮길 곳이 없다" % base)
            rc, _ = git("switch", "-c", base, "refs/remotes/%s/%s" % (base_remote, base))
            if rc != 0:
                die("%s 를 만들지 못했다. 워킹트리를 정리하고 다시 부른다" % base)
            print("  로컬에 %s 가 없어 원격에서 만들어 옮겼다" % base, file=sys.stderr)

    # ── 지우기 전에 **전부** 확인한다 ───────────────────────────
    # 검사 하나가 삭제 뒤에 있으면 「원격만 지워진」 부분 정리가 된다 (PR #64·#65).
    # 하나라도 어긋나면 아무것도 지우지 않는다.

    # 다른 worktree 가 이 브랜치를 쓰고 있나 — update-ref -d 는 branch -D 의
    # worktree 보호를 안 한다 (PR #59). 조회 실패는 「없음」이 아니다 (PR #69).
    rc, out = git("worktree", "list", "--porcelain")
    if rc != 0:
        die("worktree 목록을 못 읽었다. 지우지 않는다")
    if ("branch refs/heads/%s" % br) in out.splitlines():
        die("다른 worktree 가 %s 을 체크아웃하고 있다 — 지우면 그쪽이 커밋을 잃는다" % br)

    # 작업 트리가 아직 깨끗한가 — 큐 대기 20분 사이 편집기가 건드릴 수 있다 (PR #73).
    dirty = worktree_dirty_count()
    if dirty is None:
        die("작업 트리 상태를 못 읽었다. 지우지 않는다")
    if dirty:
        die("머지 뒤에 작업 트리가 더러워졌다(%d 개). 지우지 않는다 —\n"
            "       머지는 끝났으니 정리하고 다시 부른다:  git status --short" % dirty)

    # 로컬이 옮겨졌나 — 큐 대기 사이 다른 터미널이 커밋을 얹었을 수 있다 (PR #56).
    rc, out = git("rev-parse", "refs/heads/%s" % br)
    now_oid = out.strip() if rc == 0 else ""
    if now_oid != reviewed:
        die("로컬 %s 이 %s 로 옮겨졌다(리뷰된 것은 %s).\n"
            "       그 사이 커밋이 얹혔다 — 지우지 않는다" % (br, now_oid[:8], reviewed[:8]))

    # 원격들이 아직 리뷰된 커밋을 가리키나 — **push URL 마다** 본다 (PR #65).
    # 같은 엔드포인트 중복은 한 번만 담는다 (PR #66) — 두 번 지우면 두 번째가
    # 실패해 부분 정리가 된다.
    del_urls, seen_keys = [], set()
    for u in head_urls:
        rc, out = git("ls-remote", "--exit-code", u, "refs/heads/%s" % br, timeout=30)
        if rc == 0:
            roid = out.split()[0] if out.split() else ""
            if roid != reviewed:
                die("원격 %s 의 %s 이 %s 를 가리킨다(리뷰된 것은 %s).\n"
                    "       머지 뒤에 누가 push 했다 — 그 커밋을 지우지 않는다. 눈으로 확인한다"
                    % (redact(u), br, roid[:8], reviewed[:8]))
            khost = url_host(u)
            key = ("%s/%s" % (khost, url_nwo(u))) if khost else u
            if key not in seen_keys:
                seen_keys.add(key)
                del_urls.append(u)
        elif rc == 2:
            print("  %s 에는 이미 없다" % redact(u), file=sys.stderr)
        else:
            die("원격 %s 조회 실패 — 지워졌는지 알 수 없어 아무것도 안 지운다" % redact(u))

    # ── 여기서부터 지운다 ───────────────────────────────────────
    # 원격을 URL 마다, lease 로 리뷰된 SHA 에 묶어 지운다 — 조회와 삭제 사이의
    # push 를 막는다 (PR #57 실측: 옛 lease→거부·유지, 맞는 lease→삭제).
    for u in del_urls:
        rc, _ = git("push", u, "--force-with-lease=refs/heads/%s:%s" % (br, reviewed),
                    "--delete", br, timeout=60)
        if rc != 0:
            die("원격 %s 삭제가 거부됐다. 조회 뒤 누가 push 했다 — 눈으로 확인한다" % redact(u))

    # 로컬은 `update-ref -d <ref> <옛값>` — 대조와 삭제가 한 동작이다 (PR #58).
    rc, _ = git("update-ref", "-d", "refs/heads/%s" % br, reviewed)
    if rc != 0:
        rc2, _ = git("show-ref", "--verify", "-q", "refs/heads/%s" % br)
        if rc2 == 0:
            die("로컬 브랜치를 못 지웠다(ref 잠김·다른 worktree 에서 체크아웃)")
        print("  로컬 브랜치가 이미 없다", file=sys.stderr)

    # `branch.<이름>.*` 설정도 지운다 — 남으면 같은 이름의 새 브랜치가 옛
    # upstream 을 물려받는다 (PR #60). 없으면 실패해도 무방하다.
    git("config", "--remove-section", "branch.%s" % br)

    # 낡은 추적 ref 는 브랜치를 올린 그 원격에서 턴다. --no-write-fetch-head —
    # 사용자의 FETCH_HEAD 를 건드리지 않는다 (PR #62).
    rc, _ = git("fetch", "--no-write-fetch-head", "--prune", head_remote, timeout=60)
    if rc != 0:
        print("  prune 을 못 했다(나중에)", file=sys.stderr)
    if base_remote != head_remote:
        rc, _ = git("fetch", "--no-write-fetch-head", "--prune", base_remote, timeout=60)
        if rc != 0:
            print("  base 원격 prune 을 못 했다(나중에)", file=sys.stderr)

    print("정리 완료 — #%s 머지됨(%s), %s/%s 와 로컬 브랜치를 지웠다"
          % (pr, reviewed[:8], head_remote, br))


def worktree_dirty_count():
    """미커밋 변경 수. 조회 실패는 None — 「깨끗함」으로 읽으면 안 된다 (PR #68)."""
    rc, out = git("status", "--porcelain")
    if rc != 0:
        return None
    return sum(1 for l in out.splitlines() if l.strip())


if __name__ == "__main__":
    main()
