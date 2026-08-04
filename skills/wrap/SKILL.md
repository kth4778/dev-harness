---
name: wrap
description: 회고가 끝난 뒤, 또는 지난 세션의 산출물이 남아 있을 때 사용한다. 세션 폴더를 기록으로 옮기고 자리를 비운다.
---

# 세션 마감 (Phase 8)

**회고(`retro`)를 먼저 끝내고 온다.** 아카이브로 옮기고 나면
`workspace-guard` 훅이 `_archive/` 쓰기를 막아 회고 결과를 넣을 수 없다.

이번 세션의 것을 기록으로 옮기고 **다음 세션이 깨끗한 자리에서 시작**하게 한다.

자리를 안 비우면 다음 기능의 에이전트와 이번 기능의 에이전트가 섞인다.
어느 파일이 어느 기능 것인지 알 수 없게 되고, 그 시점부터 `_workspace/`는
쓰레기통이 된다.

## 무엇을 옮기고 무엇을 남기나

| 표시 | 대상 | 조치 |
|---|---|---|
| **[1]** | 소스 코드 | 그대로. PR로 머지됨 |
| **[2]** | `CLAUDE.md` (3층 전부) | **건드리지 않는다.** 프로젝트의 영구 자산 |
| **[2]** | `_archive/` | 여기로 옮겨 담는다 |
| **[3]** | `.claude/agents/` · `.claude/skills/` · `_workspace/` | 옮기고 **비운다** |

## 순서

## 1. 세션 기록을 쓴다

→ [`references/session-log-template.md`](references/session-log-template.md) — 세션 기록 템플릿

### 2. CLAUDE.md를 최신화한다 — 확인이 아니라 갱신이다

`inspect` 6번은 **빠진 것이 있는지 보는 자리**였다. 여기가 **실제로 고쳐 넣는
자리**다. 커밋되지 않는 파일이라 PR 일정에 안 걸리므로 마감 때 몰아서 한다.

층마다 볼 것이 다르다.

| 층 | 이번 세션에서 갱신할 것 |
|---|---|
| 3층 `<모듈>/CLAUDE.md` | 새 도메인 사실 · 새로 밟은 함정 · **패키지 구조가 바뀌었으면 그 트리** · 상태 절(구현됨/미구현) · 필수 환경변수 |
| 2층 `<repo>/CLAUDE.md` | 변경 이력 표에 한 줄 · 모듈 인덱스가 늘거나 줄었으면 반영 |
| 1층 `~/.claude/CLAUDE.md` | 건드리지 않는다. 프로젝트 사실을 전역에 쓰지 않는다 |

**빼는 것이 넣는 것만큼 중요하다.**

- **고친 결함을 "알려진 구멍" 목록에서 지운다.** 남겨두면 다음 세션이 이미
  없는 문제를 다시 조사한다. 지우되 **왜 그랬는지가 자산이면 함정 절로 옮긴다** —
  목록에서 사라지고 지식도 사라지면 같은 것을 다시 밟는다
- 날짜가 박힌 절(`## 상태 (YYYY-MM-DD)`)의 날짜를 오늘로 올린다.
  **내용을 안 고쳤으면 날짜도 안 올린다** — 낡은 내용에 새 날짜가 붙는 것이
  낡은 날짜보다 나쁘다

#### README가 낡은 것이 여기서 발견되면

**그건 Phase 5가 샌 것이다.** 이번엔 문서 PR을 따로 올려 고치고,
회고(`retro`)에 "inspect 6번을 통과했는데 샜다"를 올린다 — 체크리스트가
못 잡은 모양을 하나 배운 것이므로 다음 세션의 검사에 추가한다.

CLAUDE.md는 전부 [2]다. **아카이브로 옮기지 않는다.**

### 3. 아카이브로 옮긴다

**먼저 하네스 루트로 이동한다.** 상대 경로로 옮기므로 자리가 틀리면 산출물이
엉뚱한 곳에 쌓인다. 세션을 연 폴더와 하네스 루트는 다를 수 있다 —
루트는 `<git루트>/.harness/root`가 정하고, 세션 시작 훅이 그 값을 알려준다.

```bash
GIT_ROOT=$(git rev-parse --show-toplevel)
REL=$(head -n1 "$GIT_ROOT/.harness/root" 2>/dev/null | tr -d '\r')
cd "$GIT_ROOT/${REL:-.}" || exit 1
pwd    # 훅이 알려준 "확정됨 → …"와 같아야 한다. 다르면 멈춘다

SLUG="{YYYY-MM-DD}-{기능슬러그}"
mkdir -p "_archive/$SLUG"

[ -d .claude/agents ] && mv .claude/agents "_archive/$SLUG/agents"
[ -d .claude/skills ] && mv .claude/skills "_archive/$SLUG/skills"
[ -d _workspace ]     && mv _workspace     "_archive/$SLUG/workspace"

mkdir -p .claude/agents .claude/skills
```

`mv`를 쓴다. 복사 후 삭제가 아니라 이동이다 — 중간에 실패해도 원본이 남는다.

`.harness/root`가 없으면 저장소 루트로 떨어진다. **그 상태로 진행하지 않는다** —
루트가 미확정이라는 뜻이므로 사용자에게 먼저 묻는다.

### 4. 확인한다

같은 폴더(하네스 루트)에서 돌린다.

```bash
ls -A .claude/agents/   # 비어야 한다
ls -A .claude/skills/   # 비어야 한다
ls -d _workspace 2>/dev/null   # 없어야 한다
ls _archive/$SLUG/      # agents skills workspace 가 있어야 한다
```

세 자리가 다 비었는지 **눈으로 확인**한다. 확인 없이 끝내지 않는다.

### 5. gitignore를 점검한다

```bash
git status --porcelain | grep -E '\.claude|_workspace|_archive|CLAUDE\.md'
```

**결과가 비어야 한다.** 나오면 `.gitignore`에 빠진 항목이 있다.

```gitignore
.claude/
_workspace/
_archive/
CLAUDE.md
**/CLAUDE.md
```

## 지난 세션이 안 끝난 채로 발견됐을 때

세션 시작 시 훅이 알려준다. 두 갈래다.

| 상황 | 조치 |
|---|---|
| PR이 머지됐는데 자리가 안 비었다 | 위 순서대로 마감한다 |
| 작업이 중간에 끊겼다 | 마감하지 않는다. `_workspace/progress.md`와 `git log`를 읽고 **이어서 한다** |

**끊긴 작업을 마감으로 처리해 지우지 않는다.** 판단이 안 서면 사용자에게 묻는다.

## 마지막

사용자에게 한 줄로 보고한다.

> `{기능명}` 마감했습니다. `_archive/{슬러그}/`에 기록했고 자리를 비웠습니다.
> 다음 기능을 시작할 수 있습니다.
