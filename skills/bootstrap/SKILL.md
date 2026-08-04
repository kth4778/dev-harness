---
name: bootstrap
description: Use when starting any conversation - establishes the development workflow, the ten absolute rules, and the folder convention before any other action
---

<SUBAGENT-STOP>
서브에이전트로 특정 작업을 받아 실행 중이라면 이 스킬을 무시한다.
</SUBAGENT-STOP>

<EXTREMELY-IMPORTANT>
기능 개발·수정 요청이 오면 **코드를 쓰기 전에 Phase 1(구체화)부터** 시작한다.
"간단해서 건너뛴다"는 선택지가 아니다. 간단해 보이는 요청일수록 검증되지 않은
가정이 숨어 있고, 그 가정이 틀리면 작업 전체가 낭비된다.
</EXTREMELY-IMPORTANT>

# 개발 하네스

세션 하나 = 기능 하나 = PR 하나. 8단계를 순서대로 통과한다.

## 워크플로우

| Phase | 무엇 | 스킬 | 다음으로 가는 조건 |
|---|---|---|---|
| 1 | 구체화 | `spec` | 사용자가 설계를 승인 |
| 2 | 계획 | `plan` | 사용자가 계획을 수락 |
| 3 | 하네스 설계 | `harness-design` | 사용자가 팀 구성을 승인 |
| 4 | 개발 | `build` · `tdd-java` | 모든 태스크 완료 |
| 5 | 전수 검사 + **README 동기화** | `inspect` | 절대 규칙 10개 **전부** PASS |
| 6 | PR | `pr` | 봇 2개 리뷰 통과 후 머지 |
| 7 | 회고 | `retro` | 승격 제안에 대한 사용자 판단 |
| 8 | 세션 마감 + **CLAUDE.md 최신화** | `wrap` | [3] 자리가 비었는지 확인 |

**문서는 두 자리로 갈라져 있다.** `README.md`는 커밋되므로 **Phase 5에서
같은 PR에 태우고**, `CLAUDE.md`는 커밋되지 않으므로 Phase 8에서 마무리한다.
머지된 뒤에 README를 고치면 PR이 하나 더 필요하다(규칙 6-2).

각 Phase의 상세는 해당 스킬에 있다. 여기서는 순서와 게이트만 안다.

**게이트를 건너뛰지 않는다.** Phase 1·2·3은 사람이 승인해야 넘어가고,
Phase 5는 기계 판정이 전부 PASS여야 넘어간다.

## 폴더 규약

| 표시 | 의미 | 경로 | 세션 종료 시 |
|---|---|---|---|
| **[1]** | 프로젝트 코드 — GitHub에 올라감 | `src/`, `build.gradle`, `README.md` 등 | 남는다 (PR로 머지) |
| **[2]** | 공통 — 세션을 넘어 유지 | `CLAUDE.md`(3층 전부), `_archive/` | **절대 비우지 않는다** |
| **[3]** | 세션마다 교체 | `.claude/agents/`, `.claude/skills/`, `_workspace/` | 아카이브로 옮기고 **비운다** |

세션 마감(Phase 8)은 [3]을 `_archive/{날짜}-{기능}/`으로 옮기고 자리를 비운다.
[2]는 건드리지 않는다 — 프로젝트의 영구 자산이다. 상세 절차는 `wrap` 스킬에 있다.

`_workspace/` 파일명은 `{순번}_{에이전트}_{산출물}.md` 형식을 쓴다.
예: `01_plan-critic_findings.md`

## 시작 전 확인

**2층 `CLAUDE.md`가 없으면 기능 개발을 시작하지 않는다.** 브랜치 전략을 모르면
절대 규칙 1번을 지킬 수 없다. 사용자에게 물어 스택·브랜치 전략·모듈 구성을
확정하고 `CLAUDE.md`를 만든 뒤 Phase 1로 간다. 템플릿은 `templates/`에 있다.

**`_workspace/`가 이미 있으면** 지난 세션이 마감되지 않은 것이다. 새 기능을
시작하기 전에 `wrap` 스킬로 마감한다.

## 사용자 지시가 우선한다

`CLAUDE.md`와 사용자의 직접 요청이 이 스킬보다 우선한다.
사용자가 명시적으로 건너뛰라고 했을 때만 단계를 건너뛴다.
