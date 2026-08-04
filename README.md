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
| 6 | PR — 봇 2개 리뷰 | `pr` | 머지 |
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

## 훅 5개 — 규칙을 문장이 아니라 장치로

| 훅 | 이벤트 | 막는 것 |
|---|---|---|
| `session-start` | SessionStart | (차단 없음) 규칙 10개 + 워크플로우 + 2층 CLAUDE.md 주입 |
| `pr-guard` | PreToolUse(Bash) | `gh pr review` · `gh pr comment` — 사람 계정 리뷰 (규칙 10) |
| `commit-guard` | PreToolUse(Bash) | 보호 브랜치 커밋(1) · 테스트 미완료 커밋(2) · AI 파일 커밋(9) |
| `workspace-guard` | PreToolUse(Write\|Edit) | `_archive/` 수정 · 에이전트 정의 덮어쓰기 |
| `session-end-guard` | Stop | PR 머지됐는데 마감 안 한 채 턴 종료 |

`commit-guard`의 테스트 검사는 기계적이다 — 스테이지된 소스의 수정 시각이
마지막 테스트 결과(`build/test-results`)보다 최신이면 차단한다. Gradle·Maven
프로젝트에서만 판정하고, 빌드 도구를 모르면 판정을 포기한다.

## 설치

```bash
claude plugin marketplace add C:/AI-SW-Maestro/dev-harness
```

```bash
claude plugin install dev-harness@dev-harness
```

Windows에는 Git for Windows(bash)가 필요하다. 없으면 훅이 조용히 건너뛴다.

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
hooks/                            5개 + 폴리글롯 디스패처 + 입력 파서
skills/
  bootstrap/                      훅이 세션마다 전문을 주입
  spec/ plan/                     Phase 1~2
  harness-design/                 Phase 3 (+ references: 패턴 6종, 에이전트 템플릿)
  build/ tdd-java/                Phase 4
  inspect/ pr/ retro/ wrap/       Phase 5~8
templates/                        CLAUDE.md 2층·3층 골격
```
