#!/usr/bin/env bash
# skills/pr/scripts/merge-cleanup.sh 의 갈래를 잰다.
#
# gh 를 가짜로 갈아끼워 네트워크 없이 돌린다 — 진짜 PR 을 건드리지 않는다.
ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
SCRIPT="$ROOT/skills/pr/scripts/merge-cleanup.sh"
if [ ! -f "$SCRIPT" ]; then
    echo "  [SKIP] $SCRIPT 가 없다 — 훅만 담긴 옛 트리로 보인다"
    exit 0
fi
R=$(mktemp -d); BIN=$(mktemp -d)
trap 'rm -rf "$R" "$BIN"' EXIT

pass=0; fail=0
r() { if [ "$1" = "$2" ]; then pass=$((pass+1)); printf '  [OK ] '; else fail=$((fail+1)); printf '  [FAIL] '; fi
     printf '기대 %s / 실제 %s  %s\n' "$1" "$2" "$3"; }

# 가짜 gh. 환경변수로 행동을 바꾼다.
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
# 봇 증거 채널을 흉내 낸다. 스크립트는 리뷰 → 리뷰코멘트 → 이슈코멘트·반응
# 순으로 찾으므로, 어느 채널에 무엇을 놓는지가 갈래를 만든다.
#   GH_CH_CODEX / GH_CH_CLAUDE : review | comment | reaction | none
#   GH_REVIEWED / GH_REVIEWED_CLAUDE : 그 봇이 본 커밋(기본 현재 head)
# 스크립트는 이제 **정확한 로그인**으로 거른다.
ch()  { case "$1" in *codex*) printf '%s' "${GH_CH_CODEX:-review}" ;;
                     *claude*) printf '%s' "${GH_CH_CLAUDE:-review}" ;; esac; }
oid() { case "$1" in *codex*) printf '%s' "${GH_REVIEWED:-$GH_OID}" ;;
                     *claude*) printf '%s' "${GH_REVIEWED_CLAUDE:-${GH_REVIEWED:-$GH_OID}}" ;; esac; }
case "$1" in
  api)
    case "$*" in
      */commits/*)  printf '%s\n' "${GH_HEAD_TIME:-2020-01-01T00:00:00Z}"; exit 0 ;;
      */pulls/*/reviews*)
        for b in codex claude; do
          printf '%s' "$*" | grep -q "$b" || continue
          [ "$(ch $b)" = review ] && printf '%s\n' "$(oid $b)"
        done; exit 0 ;;
      */pulls/*/comments*)
        for b in codex claude; do
          printf '%s' "$*" | grep -q "$b" || continue
          [ "$(ch $b)" = comment ] && printf '%s\n' "$(oid $b)"
        done; exit 0 ;;
      */issues/*/comments*)
        for b in codex claude; do
          printf '%s' "$*" | grep -q "$b" || continue
          [ "$(ch $b)" = icomment ] && printf '%s\n' "1"
        done; exit 0 ;;
      */issues/*/reactions*)
        # 스크립트가 content == "+1" 을 요구한다. eyes 만 있으면 안 나온다.
        for b in codex claude; do
          printf '%s' "$*" | grep -q "$b" || continue
          case "$(ch $b)" in
            reaction)      printf '%s' "$*" | grep -q '"+1"' && printf '1\n' ;;
            reaction_eyes) : ;;
          esac
        done; exit 0 ;;
      *) printf '%s\n' "${GH_BASE_NWO:-}" ; exit 0 ;;   # base repo full_name
    esac ;;
esac
# 허용 전략은 저장소 설정이다 — repo view 로 온다.
case "$*" in
  *"repo view"*)
    # 조회 실패를 흉내낼 수 있게 둔다 — 실패를 「셋 다 허용」으로 읽으면 안 된다.
    [ "${GH_REPO_VIEW_RC:-0}" = "0" ] || exit "$GH_REPO_VIEW_RC"
    printf '%s %s %s\n' "${GH_MERGE_OK:-true}" "${GH_SQUASH_OK:-true}" "${GH_REBASE_OK:-true}"
    exit 0 ;;
esac
case "$2" in
  view)
    case "$*" in
      # 스크립트는 이 URL 로 base 저장소를 확정한다(fork 에서 fork 를
      # 조회하지 않게). `pull/<번호>` 앞이 곧 owner/repo 다.
      *' url'*|*'.url'*)      printf 'https://github.com/%s/pull/1\n' "${GH_NWO:-me/work}" ;;
      *headRefName*)          printf '%s\n' "${GH_HEAD:-feature/x}" ;;
      *baseRefName*)          printf '%s\n' "${GH_BASE:-main}" ;;
      *headRefOid*)           printf '%s\n' "${GH_OID}" ;;
      *headRepositoryOwner*)  printf '%s\n' "${GH_OWNER:-me}" ;;
      *headRepository*)       printf '%s\n' "${GH_REPO:-work}" ;;
      *state*)                printf '%s\n' "${GH_STATE:-MERGED}" ;;
    esac
    exit "${GH_VIEW_RC:-0}" ;;
  merge)
    # 브랜치 보호(선형 이력)가 특정 전략만 거부하는 상황.
    if [ -n "${GH_REJECT_STRAT:-}" ]; then
      case "$*" in *"$GH_REJECT_STRAT"*) exit 1 ;; esac
    fi
    exit "${GH_MERGE_RC:-0}" ;;
esac
GH
chmod +x "$BIN/gh"; export PATH="$BIN:$PATH"

fresh() {
    rm -rf "$R"; mkdir -p "$R/remote" "$R/work"
    # 원격 경로가 `me/work` 를 담아야 head 저장소 대조를 통과한다.
    mkdir -p "$R/me"; git init -q --bare -b main "$R/me/work"
    ln -sfn "$R/me/work" "$R/remote"
    git clone -q "$R/me/work" "$R/work" 2>/dev/null
    cd "$R/work" || exit 1
    git config user.email t@t.t; git config user.name t
    printf 'base\n' > base.txt; git add base.txt; git commit -qm init
    git push -q origin main 2>/dev/null; git remote set-head origin main 2>/dev/null
    git switch -qc feature/x
    printf 'x\n' > f.txt; git add f.txt; git commit -qm work
    git push -q -u origin feature/x 2>/dev/null
}
# PR head SHA 는 로컬 HEAD 와 같아야 통과한다. 시험이 그 값을 맞춰 준다.
run() { CLEANUP_WAIT_SEC=2 CLEANUP_POLL_SEC=1 GH_OID="${GH_OID:-$(git rev-parse HEAD)}" \
    bash "$SCRIPT" 1 2>&1; }

echo "── 정상 경로 ──"
fresh; out=$(run); rc=$?
r 0 "$rc" '머지되고 정리까지 끝난다'
r "main" "$(git rev-parse --abbrev-ref HEAD)" '통합 브랜치로 옮겨져 있다'
r "" "$(git branch --list feature/x)" '로컬 브랜치가 지워졌다'
r "" "$(git ls-remote --heads origin feature/x)" '원격 브랜치가 지워졌다'

echo "── 파괴적 오작동을 막는다 ──"
fresh; out=$(GH_HEAD=feature/other run); rc=$?
r 1 "$rc" 'PR head 가 현재 브랜치와 다르면 멈춘다'
r "feature/x" "$(git branch --show-current)" '엉뚱한 브랜치를 안 지운다'
printf '%s' "$out" | grep -q "head 는" && r y y '무엇이 어긋났는지 알린다' || r y n '무엇이 어긋났는지 알린다'

echo "── base 를 PR 에서 가져온다 ──"
fresh; git branch -q develop; git push -q origin develop 2>/dev/null
out=$(GH_BASE=develop run); rc=$?
r 0 "$rc" 'base 가 develop 이어도 돈다'
r "develop" "$(git rev-parse --abbrev-ref HEAD)" 'origin/HEAD(main) 가 아니라 PR 의 base 로 옮긴다'

echo "── 머지가 실제로 끝났는지 본다 ──"
fresh; out=$(GH_STATE=OPEN run); rc=$?
r 1 "$rc" '명령이 성공해도 상태가 OPEN 이면 멈춘다'
r "feature/x" "$(git branch --show-current)" '열린 PR 의 브랜치를 안 지운다'
fresh; out=$(GH_STATE=CLOSED run); rc=$?
r 1 "$rc" '닫혔으면 정리하지 않는다'

echo "── 조회 실패를 삼키지 않는다 ──"
fresh; out=$(GH_VIEW_RC=1 run); rc=$?
r 1 "$rc" 'gh 조회가 실패하면 즉시 멈춘다'
r "feature/x" "$(git branch --show-current)" '아무것도 안 지운다'

echo "── 머지 요청 실패 ──"
fresh; out=$(GH_MERGE_RC=1 run); rc=$?
r 1 "$rc" '머지 요청이 실패하면 멈춘다'
printf '%s' "$out" | grep -q "리뷰 뒤 push" && r y y '리뷰 후 push 가능성을 알린다' || r y n '리뷰 후 push 가능성을 알린다'

echo "── merge queue ──"
# 이제 그 플래그를 아예 안 넘기므로 queue 저장소에서도 갈래가 하나뿐이다.
# 머지 뒤 상태가 MERGED 가 되면 정리까지 간다.
fresh; out=$(run); rc=$?
r 0 "$rc" 'queue 저장소에서도 한 갈래로 머지하고 정리한다'
r "" "$(git branch --list feature/x)" '정리가 끝났다'

echo "── 원격에 이미 없을 때 ──"
fresh; git push -q origin --delete feature/x 2>/dev/null
out=$(run); rc=$?
r 0 "$rc" '이미 없으면 성공으로 친다'
r "" "$(git branch --list feature/x)" '로컬은 그래도 지운다'

echo "── 로컬 HEAD 와 PR head 를 대조한다 ──"
fresh; out=$(GH_OID=deadbeefdeadbeefdeadbeef run); rc=$?
r 1 "$rc" 'SHA 가 다르면 멈춘다(push 안 한 커밋·동명 브랜치)'
r "feature/x" "$(git branch --show-current)" 'push 안 한 커밋을 날리지 않는다'

echo "── 리뷰가 붙은 커밋에 고정한다 ──"
fresh; out=$(GH_REVIEWED=0123456789abcdef0123 run); rc=$?
r 1 "$rc" '리뷰가 다른 커밋에 붙어 있으면 멈춘다(리뷰 뒤 push)'
printf '%s' "$out" | grep -q "아무도 안 봤다" && r y y '그 커밋이 리뷰를 못 받았다고 알린다' || r y n '그 커밋이 리뷰를 못 받았다고 알린다'
fresh; out=$(GH_CH_CODEX=none GH_CH_CLAUDE=none run); rc=$?
r 1 "$rc" '리뷰가 아예 없으면 멈춘다'

echo "── 봇 둘이 각각 head 를 리뷰했는지 본다 (PR #51) ──"
fresh; out=$(GH_REVIEWED_CLAUDE=0123456789abcdef0123 run); rc=$?
r 1 "$rc" 'claude 가 옛 커밋만 리뷰했으면 멈춘다'
printf '%s' "$out" | grep -q "claude" && r y y '어느 봇이 빠졌는지 알린다' || r y n '어느 봇이 빠졌는지 알린다'

echo "── head 저장소를 대조한다 ──"
fresh; out=$(GH_OWNER=other run); rc=$?
r 1 "$rc" 'PR head 가 다른 저장소면 멈춘다'
r "feature/x" "$(git branch --show-current)" '내 브랜치를 안 지운다'

echo "── 봇 증거가 SHA 없는 채널로만 올 때 (PR #53) ──"
# 실제로 PR #33 은 codex 가 반응만, claude 가 이슈 코멘트만 남겼다.
# 그것이 **현재 head** 를 본 것인지 기계가 알 수 없으므로 자동 통과시키지 않는다.
fresh; out=$(GH_CH_CODEX=reaction GH_CH_CLAUDE=icomment run); rc=$?
r 1 "$rc" 'SHA 없는 채널만 있으면 사람 확인을 요구한다'
printf '%s' "$out" | grep -q "CLEANUP_ALLOW_SHALESS" && r y y '어떻게 넘어가는지 알려준다' || r y n '어떻게 넘어가는지 알려준다'
r "feature/x" "$(git branch --show-current)" '그때는 아무것도 안 지운다'

fresh; out=$(CLEANUP_ALLOW_SHALESS=1 GH_CH_CODEX=reaction GH_CH_CLAUDE=icomment run); rc=$?
r 0 "$rc" '사람이 확인했다고 하면 진행한다'

fresh; out=$(GH_CH_CODEX=comment GH_CH_CLAUDE=review run); rc=$?
r 0 "$rc" '인라인 리뷰 코멘트는 SHA 가 있어 자동으로 받는다'

echo "── 반응 종류를 가른다 ──"
fresh; out=$(GH_CH_CODEX=reaction_eyes GH_CH_CLAUDE=review run); rc=$?
r 1 "$rc" 'eyes(검토 시작)는 완료 증거가 아니다'

echo "── head 저장소를 정확히 대조한다 ──"
fresh; out=$(GH_REPO=work-backup run); rc=$?
r 1 "$rc" 'me/work 와 me/work-backup 을 가른다(부분문자열 아님)'

echo "── 봇 로그인을 정확히 대조한다 (PR #53) ──"
# `claude-review-helper` 같은 아무 계정이 리뷰 하나로 통과시킬 수 없어야 한다.
fresh; out=$(REQUIRED_BOTS="chatgpt-codex-connector[bot] claude[bot]" GH_CH_CLAUDE=none run); rc=$?
r 1 "$rc" '요구한 로그인이 없으면 멈춘다'

echo "── codex 지적 (PR #54) ──"
# merge commit 이 꺼진 저장소에서 --merge 만 두 번 시도하면 Phase 6 이 막힌다.
# 가짜 gh 의 기본은 셋 다 true 다. merge 만 끄면 이제 rebase 로 떨어진다.
fresh; out=$(GH_MERGE_OK=false GH_SQUASH_OK=true run); rc=$?
r 0 "$rc" 'merge commit 이 꺼져 있으면 다른 전략으로 떨어진다'
printf '%s' "$out" | grep -qE 'rebase|squash' \
  && r y y '어느 전략을 썼는지 알린다' || r y n '어느 전략을 썼는지 알린다'

# 큐를 기다리는 사이 누가 push 하면 그 커밋을 지우면 안 된다.
fresh
# 원격 브랜치를 다른 커밋으로 옮긴다(다른 사람이 push 한 셈).
printf 'other\n' > o.txt; git add o.txt; git commit -qm "남의 커밋"
git push -q origin feature/x 2>/dev/null
git reset -q --hard HEAD~1                     # 로컬은 리뷰된 커밋으로 되돌린다
out=$(run); rc=$?
r 1 "$rc" '원격이 다른 커밋을 가리키면 안 지운다'
printf '%s' "$out" | grep -q "머지 뒤에 누가 push" && r y y '왜 멈췄는지 알린다' || r y n '왜 멈췄는지 알린다'

echo "── codex 지적 (PR #56) ──"
# 큐 대기 사이 다른 터미널이 로컬에 커밋을 얹으면 그것을 날리면 안 된다.
fresh
git remote set-url --push origin "$R/me/work"
printf 'later\n' > later.txt; git add later.txt; git commit -qm "다른 터미널이 얹은 커밋"
# GH_OID 는 리뷰된(= 하나 전) 커밋으로 둔다.
out=$(GH_OID=$(git rev-parse HEAD~1) run); rc=$?
r 1 "$rc" '로컬이 앞서 있으면 멈춘다(push 안 한 커밋을 안 날린다)'
r "feature/x" "$(git branch --show-current)" '브랜치가 그대로 있다'

echo "── codex 지적 (PR #57) ──"
# --delete-branch 는 머지 직후 로컬·원격을 즉시 지운다. 그러면 뒤의 재검증이
# 지워진 ref 를 재느라 **정상 실행이 매번 실패로 끝난다.**
# grep -c 를 쓴다 — -q 는 매치하자마자 닫혀 SIGPIPE 함정을 부른다.
# 주석은 이 플래그를 **설명**한다 — 세면 안 된다. 명령줄만 본다.
r 0 "$(grep -v '^[[:space:]]*#' "$SCRIPT" | grep -c -- '--delete-branch' || true)" \
   '머지 호출에 --delete-branch 를 쓰지 않는다'

# 원격 삭제는 리뷰된 SHA 에 lease 로 묶는다 — 조회와 삭제 사이의 push 를 막는다.
r 1 "$(grep -v '^[[:space:]]*#' "$SCRIPT" | grep -c 'force-with-lease' || true)" \
   '원격 삭제를 리뷰된 SHA 에 lease 로 묶는다'

# 로컬 삭제는 `git branch -D` 가 아니라 `update-ref -d <ref> <옛값>` 이어야
# 대조와 삭제가 한 동작이 된다. 명령줄만 본다(주석은 세지 않는다).
r 0 "$(grep -v '^[[:space:]]*#' "$SCRIPT" | grep -c 'git branch -D' || true)" \
   '로컬 삭제에 git branch -D 를 쓰지 않는다'
r 1 "$(grep -v '^[[:space:]]*#' "$SCRIPT" | grep -c 'update-ref -d' || true)" \
   '로컬 삭제를 리뷰된 SHA 에 원자적으로 묶는다'

echo "── codex 지적 (PR #59) ──"
# 규칙 7 은 봇 딱 2개를 요구한다 — 환경변수로 그 목록을 바꿀 수 있으면 안 된다.
fresh
git remote set-url --push origin "$R/me/work"
# 예전에는 이 값이 빈칸이면 루프가 한 번도 안 돌아 **리뷰 증거 없이** 통과했다.
# 이제 무시하므로 정상 목록으로 검사하고, 증거가 있으니 정상 통과한다.
out=$(REQUIRED_BOTS=" " run); rc=$?
r 0 "$rc" 'REQUIRED_BOTS 를 넘겨도 정상 목록으로 검사한다'
r 0 "$(grep -v '^[[:space:]]*#' "$SCRIPT" | grep -c 'REQUIRED_BOTS' || true)" \
   '스크립트가 REQUIRED_BOTS 를 읽지 않는다'

# 다른 worktree 가 체크아웃한 브랜치는 지우지 않는다.
r 1 "$(grep -c 'git worktree list' "$SCRIPT" || true)" \
   '삭제 전에 worktree 사용 여부를 본다'

# 빠른 명령마다 1초를 버리면 안 된다.
r 0 "$(grep -v '^[[:space:]]*#' "$SCRIPT" | grep -c 'sleep 1;' || true)" \
   'bounded 가 1초 단위로 폴링하지 않는다'

echo "── codex 지적 (PR #60) ──"
# base 를 다른 worktree 가 쓰고 있으면 `git switch $BASE` 가 실패한다.
# 그때도 정리까지 끝나야 한다 — 예전에는 머지만 되고 아무것도 못 지웠다.
fresh
git remote set-url --push origin "$R/me/work"
git worktree add -q "$R/wt-main" main 2>/dev/null
out=$(run); rc=$?
r 0 "$rc" 'base 가 다른 worktree 에 있어도 정리까지 끝난다'
r "" "$(git branch --list feature/x)" '그 경우에도 로컬 브랜치가 지워졌다'
printf '%s' "$out" | grep -q "다른 worktree" \
  && r y y 'detach 로 나왔음을 알린다' || r y n 'detach 로 나왔음을 알린다'
git worktree remove --force "$R/wt-main" 2>/dev/null || true

# 지운 브랜치의 설정이 남으면 같은 이름을 다시 팔 때 옛 upstream 을 물려받는다.
r 1 "$(grep -c 'remove-section' "$SCRIPT" || true)" \
   '브랜치 설정도 함께 지운다'

# PR 호스트는 PR 자신의 URL 에서 구해야 한다.
# `GH_HOST=` 를 만드는 줄만 본다. BASE_REMOTE 폴백이 같은 설정을 읽는 것은
# 정당하다 — 거기는 「어느 원격에서 당길까」를 고르는 자리다.
# 이제 PR URL 에서 호스트를 한 번 뽑아(API_HOST) 그것을 재사용한다.
r 1 "$(grep -c 'API_HOST=$(printf' "$SCRIPT" || true)" \
   'PR 호스트를 PR 자신의 URL 에서 구한다'
r 1 "$(grep -v '^[[:space:]]*#' "$SCRIPT" | grep -c 'API_HOST=$(printf' || true)" \
   'gh 에 넘길 호스트는 원형 그대로 둔다'

echo "── codex 지적 (PR #61) ──"
# Enterprise 에 있는 PR 은 gh api 기본 호스트(github.com)로 조회하면 증거를
# 못 봐서 **항상** 막힌다. 네 조회 전부에 호스트를 넘겨야 한다.
r 4 "$(grep -c 'gh api --hostname' "$SCRIPT" || true)" \
   'gh api 조회 전부에 PR 호스트를 넘긴다'

# `claude[bot]` 은 파일명 패턴이기도 하다 — 인용 없이 확장하면 파일명으로 바뀐다.
fresh
git remote set-url --push origin "$R/me/work"
: > claudeb; : > claudeo          # 패턴에 맞는 파일을 만든다
# 커밋한다 — 작업 트리가 더러우면 그 검사에 먼저 걸린다.
git add claudeb claudeo; git commit -qm "chore: 패턴에 맞는 파일"
git push -q origin feature/x 2>/dev/null
out=$(GH_OID=$(git rev-parse HEAD) run); rc=$?
r 0 "$rc" '작업 폴더에 claudeb 같은 파일이 있어도 봇 로그인이 안 망가진다'

# 짧은 이름은 ref 이름의 **끝부분**에도 맞는다 — 전체 ref 로 조회해야 한다.
r 0 "$(grep -v '^[[:space:]]*#' "$SCRIPT" | grep -c 'ls-remote --exit-code --heads' || true)" \
   'ls-remote 를 짧은 이름으로 조회하지 않는다'
r 1 "$(grep -c 'refs/heads/\$BR" > "\$RLS"' "$SCRIPT" || true)" \
   'ls-remote 에 전체 ref 를 넘긴다'

# `https://host/me/work.git/` 같은 URL 도 me/work 로 모여야 한다.
fresh
git remote set-url --push origin "$R/me/work/"
out=$(run); rc=$?
r 0 "$rc" 'push URL 끝에 슬래시가 있어도 저장소를 같게 본다'

echo "── codex 지적 (PR #62) ──"
# squash 는 하위 기능별 커밋을 하나로 뭉갠다 — rebase 가 가능하면 그쪽이 먼저다.
fresh; out=$(GH_MERGE_OK=false GH_SQUASH_OK=true GH_REBASE_OK=true run); rc=$?
r 0 "$rc" 'merge 가 꺼져 있어도 돈다'
printf '%s' "$out" | grep -q -- '--rebase' \
  && r y y 'squash 보다 rebase 를 먼저 고른다' || r y n 'squash 보다 rebase 를 먼저 고른다'

fresh; out=$(GH_MERGE_OK=false GH_SQUASH_OK=true GH_REBASE_OK=false run); rc=$?
printf '%s' "$out" | grep -q -- '--squash' \
  && r y y 'rebase 도 꺼져 있으면 squash 로 내려간다' || r y n 'rebase 도 꺼져 있으면 squash 로 내려간다'

# fetch 가 사용자의 FETCH_HEAD 를 덮어쓰면 안 된다.
r 0 "$(grep -v '^[[:space:]]*#' "$SCRIPT" \
         | grep 'git fetch' | grep -vc 'no-write-fetch-head' || true)" \
   'fetch 전부가 FETCH_HEAD 를 건드리지 않는다'

echo "── codex 지적 (PR #63) ──"
# 머지 설정 조회가 실패하면 「셋 다 허용」으로 깔지 말고 멈춘다.
# 예전에는 빈 응답을 읽고 --merge 를 골라, merge 가 꺼진 저장소에서 Phase 6 이
# 막혔다 — 쓸 수 있는 대체 전략이 있는데도 그랬다.
fresh; out=$(GH_REPO_VIEW_RC=1 run); rc=$?
r 1 "$rc" '머지 설정을 못 읽으면 멈춘다'
r "feature/x" "$(git branch --show-current)" '그때는 아무것도 안 지운다'

# `git pull` 은 --no-write-fetch-head 를 못 받는다 — 쓰지 않아야 한다.
r 0 "$(grep -v '^[[:space:]]*#' "$SCRIPT" | grep -c 'git pull' || true)" \
   'git pull 을 쓰지 않는다(FETCH_HEAD 를 덮어쓴다)'
r 1 "$(grep -c 'merge --ff-only' "$SCRIPT" || true)" \
   'fetch 와 fast-forward 로 나눈다'

# 원격 브랜치 조회는 push URL 로 한다 — 이름은 fetch URL 을 본다.
# 이제 URL 을 하나씩 돌며 조회한다 — 이름(fetch URL)으로 부르지 않는다.
r 0 "$(grep -v '^[[:space:]]*#' "$SCRIPT" \
         | grep -c 'ls-remote --exit-code "\$HEAD_REMOTE"' || true)" \
   '원격 브랜치를 이름(fetch URL)으로 조회하지 않는다'
r 1 "$(grep -c 'ls-remote --exit-code "\$u"' "$SCRIPT" || true)" \
   '원격 브랜치를 push URL 마다 조회한다'

# 삼각 워크플로: fetch 와 push URL 이 다르면 push 쪽을 봐야 한다.
fresh
git remote set-url --push origin "$R/me/work"
git remote set-url origin "$R/me/work"     # fetch 도 같게 두고 정상 경로 확인
out=$(run); rc=$?
r 0 "$rc" 'push URL 로 조회해도 정상 경로가 돈다'
r "" "$(git ls-remote --heads "$R/me/work" feature/x)" '원격 브랜치가 지워졌다'

echo "── codex 지적 (PR #64) ──"
# push URL 이 둘이면 둘 다 검증해야 한다. 하나가 다른 저장소면 멈춘다.
fresh
git remote set-url --push origin "$R/me/work"
mkdir -p "$R/other"; git init -q --bare -b main "$R/other/work"
git remote set-url --add --push origin "$R/other/work"
out=$(run); rc=$?
r 1 "$rc" 'push URL 이 둘이고 하나가 다른 저장소면 멈춘다'
r 1 "$(git ls-remote --heads "$R/me/work" feature/x | grep -c . || true)" \
   '그때는 원격 브랜치도 그대로다'
r "feature/x" "$(git branch --show-current)" '그때는 로컬 브랜치도 그대로다'

# worktree 검사는 **원격 삭제 앞**에 있어야 한다. 뒤에 있으면 원격만 지워진
# 부분 정리 상태가 되고, 다시 불러도 원격이 없어 복구가 안 된다.
#
# 이 상황은 스크립트가 도는 **중간에** 다른 worktree 가 끼어드는 것이라 실행으로
# 재현할 수 없다. 코드에서 두 검사의 순서를 잰다.
wt_line=$(grep -n 'git worktree list' "$SCRIPT" | awk -F: 'NR==1{print $1}')
del_line=$(grep -n 'force-with-lease' "$SCRIPT" | awk -F: 'NR==1{print $1}')
r y "$([ -n "$wt_line" ] && [ -n "$del_line" ] && [ "$wt_line" -lt "$del_line" ] \
        && echo y || echo n)" \
   'worktree 검사가 원격 삭제보다 앞에 있다'

echo "── codex 지적 (PR #65) ──"
# push URL 이 둘이고 **둘 다 같은 저장소**면, 둘 다 지워야 「정리 완료」다.
fresh
# 경로가 `me/work` 로 끝나야 저장소 대조를 통과한다 — 같은 저장소의 미러다.
mkdir -p "$R/mirror/me"; git init -q --bare -b main "$R/mirror/me/work"
git remote set-url --push origin "$R/me/work"
git remote set-url --add --push origin "$R/mirror/me/work"
git push -q "$R/mirror/me/work" feature/x 2>/dev/null
out=$(run); rc=$?
r 0 "$rc" 'push URL 이 둘이어도 정상 경로가 돈다'
r 0 "$(git ls-remote --heads "$R/me/work" feature/x | grep -c . || true)" \
   '첫 원격에서 지워졌다'
r 0 "$(git ls-remote --heads "$R/mirror/me/work" feature/x | grep -c . || true)" \
   '두 번째 원격에서도 지워졌다'

# 모든 사전 검사가 원격 삭제보다 앞에 있어야 부분 정리가 안 난다.
del_line=$(grep -n 'force-with-lease' "$SCRIPT" | awk -F: 'NR==1{print $1}')
for chk in 'git worktree list' 'NOW_OID=' 'ls-remote --exit-code'; do
    ln=$(grep -n "$chk" "$SCRIPT" | awk -F: 'NR==1{print $1}')
    r y "$([ -n "$ln" ] && [ "$ln" -lt "$del_line" ] && echo y || echo n)" \
       "「$chk」 검사가 원격 삭제보다 앞에 있다"
done

# 진단에 자격 증명이 실리면 안 된다.
r 1 "$(grep -c '^redact()' "$SCRIPT" || true)" 'URL 을 가리는 함수가 있다'
r 0 "$(grep -v '^[[:space:]]*#' "$SCRIPT" | grep -c 'die "원격 $u' || true)" \
   '원본 URL 을 그대로 진단에 싣지 않는다'

echo "── codex 지적 (PR #66) ──"
# 같은 원격이 두 번 등록돼 있으면 한 번만 지워야 한다. 두 번 지우면 두 번째가
# 실패해 **원격은 지워졌는데 로컬은 남는** 부분 정리가 된다.
fresh
git remote set-url --push origin "$R/me/work"
git remote set-url --add --push origin "$R/me/work"   # 같은 URL 을 또 넣는다
out=$(run); rc=$?
r 0 "$rc" '같은 push URL 이 두 번 있어도 정상 경로가 돈다'
r "" "$(git branch --list feature/x)" '로컬까지 정리됐다'

# 기본 포트는 떼고 사내 포트는 구분한다. 함수만 뽑아 별도 파일로 읽힌다 —
# 중첩 heredoc 안에서는 바깥 변수가 안 넘어간다.
FN=$(mktemp); sed -n '/^url_host()/,/^}/p' "$SCRIPT" > "$FN"
r "github.com"      "$(. "$FN"; url_host ssh://git@github.com:22/me/w.git)" 'ssh 기본 포트 22 를 뗀다'
r "github.com"      "$(. "$FN"; url_host https://github.com:443/me/w)"      'https 기본 포트 443 을 뗀다'
r "git.ex.com:8443" "$(. "$FN"; url_host https://git.ex.com:8443/me/w)"     '사내 포트는 남긴다'
rm -f "$FN"

echo "── codex 지적 (PR #67) ──"
# 커밋되지 않은 변경이 있으면 **머지 전에** 멈춘다. 안 그러면 서버만 머지되고
# 브랜치를 못 옮겨 정리가 중간에 선다.
fresh
git remote set-url --push origin "$R/me/work"
printf 'dirty\n' > dirty.txt          # 추적 안 된 파일
out=$(run); rc=$?
r 1 "$rc" '작업 트리가 더러우면 머지 전에 멈춘다'
printf '%s' "$out" | grep -q "커밋되지 않은 변경" \
  && r y y '무엇이 문제인지 알린다' || r y n '무엇이 문제인지 알린다'
r "feature/x" "$(git branch --show-current)" '아무것도 안 지운다'

# 추적 파일을 고친 경우도 같다.
fresh
git remote set-url --push origin "$R/me/work"
printf 'changed\n' >> f.txt 2>/dev/null || printf 'changed\n' >> base.txt
out=$(run); rc=$?
r 1 "$rc" '추적 파일이 바뀐 경우도 멈춘다'

# 대조용 호스트도 push URL 과 같은 규칙으로 정규화해야 한다.
r 1 "$(grep -c 'GH_HOST=$(url_host "$PR_URL")' "$SCRIPT" || true)" \
   '대조용 호스트를 url_host 로 정규화한다'

echo "── codex 지적 (PR #68) ──"
# `git status` 조회 자체가 실패하면 「깨끗함」으로 읽지 않는다.
r 0 "$(grep -v '^[[:space:]]*#' "$SCRIPT" \
         | grep -c 'git status --porcelain 2>/dev/null | grep -c' || true)" \
   'status 를 파이프로만 세지 않는다'
r 1 "$(grep -c 'die "작업 트리 상태를 못 읽었다' "$SCRIPT" || true)" \
   'status 조회 실패를 멈춤으로 다룬다'

echo "── codex 지적 (PR #69) ──"
# 저장소 설정이 열려 있어도 base 브랜치 보호가 특정 전략을 거부할 수 있다.
# 그때 허용된 다른 전략으로 다시 넣어야 Phase 6 이 안 멈춘다.
fresh
git remote set-url --push origin "$R/me/work"
out=$(GH_REJECT_STRAT=--merge run); rc=$?
r 0 "$rc" '보호 규칙이 --merge 를 거부하면 다른 전략으로 넣는다'
printf '%s' "$out" | grep -q "다시 넣는다" \
  && r y y '무엇으로 갈아탔는지 알린다' || r y n '무엇으로 갈아탔는지 알린다'
r "" "$(git branch --list feature/x)" '그래도 정리까지 끝난다'

# 전부 거부되면 멈춘다.
fresh
git remote set-url --push origin "$R/me/work"
out=$(GH_MERGE_RC=1 run); rc=$?
r 1 "$rc" '어느 전략으로도 안 되면 멈춘다'

# worktree 조회 자체가 실패하면 「없음」으로 읽지 않는다.
r 1 "$(grep -c 'die "worktree 목록을 못 읽었다' "$SCRIPT" || true)" \
   'worktree 조회 실패를 멈춤으로 다룬다'

# 시한 초과 때 자식까지 죽인다 — git 이 띄운 ssh 가 남으면 안 된다.
r 1 "$(grep -c 'kill -TERM "-\$pid"' "$SCRIPT" || true)" \
   '프로세스 그룹 전체에 TERM 을 보낸다'
r 1 "$(grep -c 'kill -KILL "-\$pid"' "$SCRIPT" || true)" \
   '프로세스 그룹 전체에 KILL 을 보낸다'

echo "── codex 지적 (PR #70) ──"
# `CLEANUP_ALLOW_SHALESS` 는 **정확히 1** 일 때만 연다. 끄려고 쓰는 값이
# 「사람이 확인했다」로 읽히면 안 된다.
for v in 0 false no ""; do
    fresh
    out=$(CLEANUP_ALLOW_SHALESS="$v" GH_CH_CODEX=reaction GH_CH_CLAUDE=icomment run)
    r 1 "$?" "CLEANUP_ALLOW_SHALESS='$v' 로는 열리지 않는다"
done
fresh
out=$(CLEANUP_ALLOW_SHALESS=1 GH_CH_CODEX=reaction GH_CH_CLAUDE=icomment run)
r 0 "$?" "CLEANUP_ALLOW_SHALESS=1 이면 진행한다"

# 로컬에 base 브랜치가 없으면(single-branch clone) 만들어 옮긴다.
# 예전에는 detach 로 처리해 **지워진 커밋에 HEAD 가 남았다.**
fresh
git remote set-url --push origin "$R/me/work"
# 로컬 base **와 원격 추적 ref** 를 둘 다 없앤다. 추적 ref 가 남아 있으면
# `git switch main` 이 그것에서 자동으로 브랜치를 만들어, 이 갈래를 안 탄다.
git branch -D main 2>/dev/null || true
git update-ref -d refs/remotes/origin/main 2>/dev/null || true
out=$(run); rc=$?
r 0 "$rc" '로컬에 base 가 없어도 정리까지 끝난다'
r "main" "$(git rev-parse --abbrev-ref HEAD)" 'base 를 만들어 그쪽에 서 있다'
printf '%s' "$out" | grep -q "만들어 옮겼다" \
  && r y y '무엇을 했는지 알린다' || r y n '무엇을 했는지 알린다'

echo
echo "════ 합계: OK $pass / FAIL $fail ════"
[ "$fail" -eq 0 ]
