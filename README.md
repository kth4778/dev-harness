# dev-harness

기능 구체화부터 PR·세션 마감까지 강제하는 개발 하네스.

**세션 하나 = 기능 하나 = PR 하나.**

## 워크플로우

| Phase | 무엇 | 스킬 | 다음으로 가는 조건 |
|---|---|---|---|
| 0 | 세션 시작 | (훅) | — |
| 1 | 구체화 — 한 번에 한 질문, 모호성이 기준 아래로 | `spec` | 사용자 승인 |
| 2 | 계획 — 파일 경로·코드·검증 명령까지 | `plan` | 사용자 수락 |
| 3 | 하네스 설계 — 이 기능에 맞는 에이전트 팀 | `harness-design` | 사용자 승인 |
| 4 | 개발 — TDD, 태스크마다 리뷰 | `build` · `tdd-java` | 모든 태스크 완료 |
| 5 | 전수 검사 — 규칙 10개 + 서버 실제 기동 + **README 동기화** | `inspect` | **전부 PASS** |
| 6 | PR — 봇 2개 리뷰 + **지식 위키 반영** | `pr` | 머지 |
| 7 | 회고 — 실수를 규칙으로 승격 | `retro` | 사용자 판단 |
| 8 | 세션 마감 — 기록하고 **CLAUDE.md 최신화**하고 자리 비우기 | `wrap` | 자리 확인 |

절대 규칙 10개는 [RULES.md](RULES.md)에 있다.

### 문서가 두 자리로 갈라진 이유

| 문서 | 커밋 | Phase |
|---|---|---|
| `README.md` | **된다** | **5** — 코드와 같은 PR에 태운다 |
| `CLAUDE.md` | 안 된다 (규칙 9) | 8 — 마감할 때 |

머지된 뒤에 README를 고치면 **PR이 하나 더 든다.** `CLAUDE.md`만 최신인 상태는
최신이 아니다 — 그 파일은 커밋되지 않아 팀원에게 도달하지 않는다.
규칙 6-2가 이것이다.

### 세 번째 자리 — 코드 저장소 밖의 지식 위키

팀 지식 정본이 **다른 저장소**에 있으면 같은 PR에 태울 수 없다. 그래서 코드만
머지되고 정본은 옛 사실을 말하는 상태가 생긴다 — 계약 엔드포인트 이름이 구현과
갈리거나, 결정 문서의 "반영 완료" 체크가 사실이 아닌 채로 남는다.

`<git루트>/.harness/wiki` 한 줄이 그 저장소를 가리키고, **없으면 건너뛴다.**
Phase 6에서 **별도 PR**로 올린다. 규칙 6-3이 이것이다.

## 훅 7개 — 되돌릴 수 없는 것만 막는다

| 훅 | 이벤트 | 막는 것 |
|---|---|---|
| `session-start` | SessionStart | (차단 없음) 규칙 **제목** + 워크플로우 + 2층 CLAUDE.md + 3층 **경로** 주입 |
| `pr-guard` | PreToolUse(Bash) | `gh pr review` · `gh pr comment` — 사람 계정 리뷰 (규칙 10) |
| `commit-guard` | PreToolUse(Bash) | 보호 브랜치 커밋(1) · AI 파일 커밋(9) |
| `secret-guard` | PreToolUse(Bash) | 스테이지에 시크릿(AWS 키·토큰·개인키)이 든 커밋 |
| `workspace-guard` | PreToolUse(Write\|Edit) | `_archive/` 수정 · 에이전트 정의 덮어쓰기 |
| `stamp-guard` | PreToolUse(Bash) | 검토 도장 이후에 운영 코드가 바뀐 채로 `gh pr create` |
| `worktree-guard` | PreToolUse(Bash) | 에이전트가 도는 중에 `git switch`·`checkout`·`reset --hard` |

**기준은 "되돌릴 수 있나"다.** public 저장소에 한 번 올라간 시크릿과 보호
브랜치 커밋은 지워도 히스토리에 남고, 나간 PR 코멘트는 지워도 알림이 이미
갔다. 이런 것만 기계가 막는다.

되돌릴 수 있는 실수는 훅으로 막지 않는다. 추측으로 막다 보면 오탐이 쌓이고,
오탐이 쌓이면 훅 전체를 우회하게 된다 — 그러면 위의 넷도 같이 무력해진다.

### 뺀 것 (0.5.0)

| 뺀 것 | 이유 |
|---|---|
| `session-end-guard` (Stop) | 마감 안 했다고 턴 종료를 막았다. 막는 대상이 되돌릴 수 있는 것이고, 같은 사실을 다음 세션 시작 훅이 이미 알려준다 |
| `commit-guard`의 테스트 검사 | 소스 수정 시각과 `build/test-results` 시각을 비교했다. 주석 한 줄만 고쳐도, Gradle이 up-to-date로 건너뛰어도 걸렸다 |

규칙 2(테스트를 마친 커밋)는 사라진 게 아니라 **훅에서 사람의 판단으로
옮겼다.** `inspect`가 커밋을 하나씩 체크아웃해 실제로 돌려본다.

### 주입량 (0.5.0)

**30.6KB → 11.5KB.** 셋을 줄였다.

| | 전 | 후 |
|---|---|---|
| `RULES.md` | 전문 6.7KB | **제목 10줄** + 파일 경로 |
| 3층 CLAUDE.md | 전문 25KB가 통째로 | **경로와 크기만.** 모듈 코드를 건드리기 전에 읽는다 |
| 2층 CLAUDE.md | **버그로 안 들어갔다** | 저장소 루트에서 읽어 정상 주입 |

세 번째가 버그였다. 하네스 루트가 모듈(`services/auth`)이면
`${PROJECT_DIR}/CLAUDE.md`가 3층을 가리키는데, 그걸 "2층"이라는 이름표로
주입하고 있었다. **브랜치 전략이 든 진짜 2층은 한 번도 안 들어갔다** —
규칙 1의 근거가 통째로 빠진 채였다.

제목 추출에 실패하면(`RULES.md`의 `## N.` 형식이 바뀌면) 전문으로 되돌린다.
규칙이 조용히 사라지는 것보다 길게 들어가는 편이 안전하다.

## 설치

```bash
claude plugin marketplace add C:/AI-SW-Maestro/dev-harness
```

```bash
claude plugin install dev-harness@dev-harness
```

Windows에는 Git for Windows(bash)가 필요하다. 없으면 훅이 조용히 건너뛴다.

### Windows 디스패처의 함정 둘 — 훅 전체를 조용히 무력화한다

`hooks/run-hook.cmd`는 cmd.exe와 bash가 같이 읽는 폴리글롯이다. **여기가 깨지면
훅 여섯 개가 전부 안 도는데, 아무 표시도 안 난다.** 2026-08-07에 둘 다 실물로 겪었다.

**1. 이 파일에 비ASCII 문자를 넣지 마라.**

cmd.exe는 `.cmd`를 OEM 코드페이지(한국어 Windows면 cp949)로 읽는다. UTF-8 한글
바이트가 그렇게 디코딩되면 **cmd의 명령 구분자가 튀어나와 `REM` 줄이 쪼개지고
뒷부분이 명령으로 실행된다.** 그러다 `exit /b 1`로 죽는다.

**Claude Code에서 exit 1은 "차단"이 아니라 "오류지만 통과"다.** 그래서 훅이
전부 통과 판정을 내리고, 로그에도 아무것도 안 남는다.

**2. 괄호 블록 안에 `exit /b %ERRORLEVEL%`를 쓰지 마라.**

cmd는 괄호 블록을 **파싱할 때 통째로** `%ERRORLEVEL%`를 전개한다. 즉 안쪽
명령이 **돌기 전** 값이 박힌다. 훅이 `2`(차단)로 끝나도 디스패처는 `0`(통과)을
돌려준다. 호출과 `exit /b`를 **최상위에** 둔다.

**둘 다 "설치돼 있고 문법도 맞는데 아무 일도 안 하는" 모양이다.** 그래서
고친 뒤에는 반드시 **차단이 실제로 나는지 종료 코드로 확인한다.**

```bash
printf 'x\n' > .harness/agents-running
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git switch main"}}' \
  | hooks/run-hook.cmd worktree-guard; echo "exit=$?"   # 2여야 한다
rm -f .harness/agents-running
```

**훅 스크립트는 실행 권한 비트가 있어야 한다.** Windows에서 새로 만들면 git이
`100644`로 기록한다 — `git update-index --chmod=+x hooks/<이름>`으로 세운다.
이 기계에서는 로컬 파일이 실행 가능해 안 드러나고 **새로 클론한 사람에게만 터진다.**

## 합격 테스트

대화 기록이 없는 깨끗한 세션에서 정확히 이 한 줄을 보낸다.

```
로그인 기능 만들어줘
```

**합격:** 코드를 한 줄도 쓰지 않고 구체화 질문이 나온다.
**불합격:** 코드를 쓰기 시작하거나, 계획부터 세운다.

불합격이면 발동 장치(SessionStart 훅)가 안 붙은 것이지 스킬 내용의 문제가 아니다.

추가 검사:

| 검사 | 방법 | 합격 |
|---|---|---|
| 규칙 주입 | "지켜야 할 규칙 뭐야?" | 10개를 그대로 답한다 |
| 커밋 차단 | develop에서 커밋 시도 | 훅이 막는다 |
| 리뷰 차단 | `gh pr comment` 시도 | 훅이 막는다 |

## 폴더 규약

| 표시 | 의미 | 경로 | 세션 종료 시 |
|---|---|---|---|
| **[1]** | 프로젝트 코드 — GitHub에 올라감 | `src/`, `build.gradle` | 남는다 |
| **[2]** | 공통 — 세션을 넘어 유지 | `CLAUDE.md`(3층), `_archive/` | **비우지 않는다** |
| **[3]** | 세션마다 교체 | `.claude/agents/`, `.claude/skills/`, `_workspace/` | 아카이브 후 비운다 |

프로젝트 `.gitignore`에 추가할 것:

```gitignore
.claude/
_workspace/
_archive/
CLAUDE.md
**/CLAUDE.md
```

## CLAUDE.md 3층

| 층 | 위치 | 담는 것 |
|---|---|---|
| 1층 | `~/.claude/CLAUDE.md` | 전역 — 모든 프로젝트 공통 |
| 2층 | `<repo>/CLAUDE.md` | 스택·브랜치 전략·모듈 인덱스·변경 이력 |
| 3층 | `<repo>/<모듈>/CLAUDE.md` | 모듈 도메인 사실·함정 |

상위 층은 포인터만 둔다. 골격은 [templates/](templates/)에 있다.

## 구성

```
RULES.md                          절대 규칙 10개 — 단일 원본
hooks/                            6개 + 폴리글롯 디스패처 + 입력 파서
skills/
  bootstrap/                      훅이 세션마다 전문을 주입
  spec/ plan/                     Phase 1~2
  harness-design/                 Phase 3 (+ references: 패턴 6종, 에이전트 템플릿)
  build/ tdd-java/                Phase 4
  inspect/ pr/ retro/ wrap/       Phase 5~8 (pr references: 봇 리뷰 대응, 위키 반영)
templates/                        CLAUDE.md 2층·3층 골격
```
