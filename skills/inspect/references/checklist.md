## 10개 판정

### 1. 브랜치 전략

```bash
git rev-parse --abbrev-ref HEAD
```
feature 브랜치인가. 베이스가 프로젝트 CLAUDE.md가 정한 대상인가.

**head와 base 이름이 둘 다 ASCII인가.**

```bash
# BASE 를 덮어쓰지 마라 — SKILL.md 가 merge-base SHA 로 쓰고, 아래 판정들이
# `$BASE..HEAD` 로 그것을 참조한다. 브랜치 이름으로 바꾸면 공통 조상이 아니라
# 두 tip 을 비교하게 되어 upstream 변경이 검사 대상에 섞인다.
#
# BASE_BRANCH 는 **PR 의 base 로 쓸 값**이다. origin/HEAD 를 그냥 믿지 마라 —
# 프로젝트 CLAUDE.md 가 develop 이나 release 를 통합 브랜치로 정했으면
# origin/HEAD(main)와 다르고, 검사가 엉뚱한 이름을 본다. 정한 값을 적는다.
BASE_BRANCH=develop    # ← 프로젝트 CLAUDE.md 가 정한 통합 브랜치. 없으면 아래 기본값
[ -n "$BASE_BRANCH" ] || BASE_BRANCH=$(git symbolic-ref -q --short refs/remotes/origin/HEAD | sed 's|^origin/||')
printf '%s\n%s\n' "$(git rev-parse --abbrev-ref HEAD)" "$BASE_BRANCH" | LC_ALL=C grep -n '[^ -~]'
```

**뭐라도 나오면 FAIL이다.** `anthropics/claude-code-action`이 **base** 이름을
검증하고 비ASCII를 거부한다 — 잡이 27초 만에 죽는다. base일 때만 터지므로
head만 보면 안 보인다. 이 저장소의 리뷰 워크플로가 그 액션을 쓴다.

**이 브랜치로 PR이 이미 열렸던 적이 있는가.**

```bash
BR=$(git rev-parse --abbrev-ref HEAD)
# head 저장소 owner 는 **이 브랜치가 push 되는 remote** 에서 유도한다.
# `gh repo view` 는 gh 가 향하는 저장소(fork 라면 upstream)를 주므로 head 와 다르다.
# push 대상은 pushRemote > pushDefault > remote 순으로 정해진다.
# 마지막 것만 보면 fork 로 push 하는 설정에서 소유자를 잘못 짚는다.
HEAD_REMOTE=$(git config "branch.$BR.pushRemote" \
  || git config remote.pushDefault \
  || git config "branch.$BR.remote" \
  || echo origin)
HEAD_OWNER=$(git remote get-url "$HEAD_REMOTE" \
  | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#/[^/]+$##; s#\.git$##')
gh pr list --state all --head "$BR" \
  --json number,title,state,headRepositoryOwner \
  -q ".[] | select(.headRepositoryOwner.login == \"$HEAD_OWNER\")"
```

**하나라도 나오면 FAIL이다.** 상태별로 이유가 다르다.

| 상태 | 왜 FAIL인가 |
|---|---|
| `MERGED` | 다시 쓰면 스택 PR이 되어 claude 리뷰가 아예 안 돈다 |
| `CLOSED` | 봇 지적을 받고 새 브랜치로 갈아탄 자리다. 되돌아가면 그 라운드가 다시 열린다 |
| `OPEN` | 같은 브랜치에 또 push하면 **둘 다 새로 안 돈다** — codex는 push를 트리거로 안 쓰고, claude 워크플로에는 `synchronize`가 없다. **두 리뷰가 옛 커밋에 머물고 고친 코드는 아무도 안 본다**(브랜치 동결) |

`merged`만 보면 **닫힌 쪽을 통째로 놓친다.** 리뷰 한 라운드마다 닫힌 브랜치가
하나씩 쌓이므로 이쪽이 오히려 흔하다.

`headRepositoryOwner`로 거르는 이유: `--head`는 이름만 보고 저장소를 못 가린다
(`<owner>:<branch>` 미지원). fork를 받는 저장소에서는 **남이 같은 이름으로 열었던
PR이 내 브랜치를 FAIL로 만든다.** 반대로 내가 fork에서 작업하는 경우
`gh repo view`가 upstream을 가리켜 **내 옛 PR을 못 찾는다** — 그래서 owner를
브랜치의 push 대상 remote에서 유도한다.

통합 브랜치에서 새 브랜치를 파고 옮긴다.

> 머지할 때 `--delete-branch`를 쓰면 이 상황 자체가 안 생긴다. 이 검사는
> 그것이 실패했거나 옛 브랜치가 살아남은 경우를 받는 자리다. 훅으로 막던
> 것을 걷어냈으므로(README 「넣었다가 뺀 것」) 여기가 유일한 강제 지점이다.

### 2. 커밋 단위

```bash
git log --oneline "$BASE"..HEAD
```

**하위 기능 수를 세고 커밋 수와 비교한다.** 남을 단위는 하위 기능 하나당
둘이다 — 만든 커밋과 검증하는 커밋(규칙 2).

| 신호 | 무엇을 뜻하나 |
|---|---|
| 커밋 수가 하위 기능 × 2 보다 **많다** | 리뷰 왕복이 접히지 않았다 |
| 같은 파일·같은 함수를 **세 번 이상** 건드린 커밋들 | 한 자리를 여러 번 고쳤다 → 최종 형태로 접는다 |
| `chore: …켠다` ↔ `…끈다` 처럼 **상쇄하는 쌍** | 둘 다 아무것도 안 한 것이다 → 접는다 |
| `test: …통과하던 것을 막는다` | 헛통과를 뒤늦게 막은 것 → 원래 `test:` 커밋에 흡수 |

```bash
# 같은 파일을 몇 번씩 건드렸나
git log --format=%H "$BASE"..HEAD | while read -r c; do git show --name-only --format= "$c"; done \
  | sort | uniq -c | sort -rn | head
```

**접는 것은 Phase 6이 아니라 여기서 판정한다.** 이미 push한 뒤에는 못 접으므로
(force push가 봇 리뷰를 떠 버린다) 첫 push 전인 이 자리가 마지막 기회다.

2026-08-11 실측: PokeClip PR #34에 커밋 51개가 들어갔고 하위 기능은 12개였다.
**차이 27개가 리뷰 왕복이다.** 이 검사가 없어서 그대로 머지됐다.

**접은 뒤 테스트를 다시 돌린다** — 접힌 조합으로는 한 번도 안 돌아봤다.

**테스트 판정은 1회 실행으로 쓰지 않는다. 최소 5회다.**

한 번 초록인 것을 "실패 0"이라고 적으면 안 된다. 2026-08-06에 그렇게 썼다가
**같은 코드가 16회 중 4회(25%) 빨간불**인 것을 놓쳤다. 그 판정표는 다른 항목에는
"20회 돌려 숫자를 내라"고 요구하면서 자기 판정만 1회로 했다 — **이중잣대였다.**

같은 규칙이 이틀 뒤 두 번째를 잡았다. 실서버 프로브 테스트가 **토큰 만료마다
빌드를 빨갛게** 만들고 있었는데, 6회 반복이 그것을 드러냈다.

```bash
for i in 1 2 3 4 5; do
  rm -rf <결과 XML 디렉터리>
  ./gradlew test
  # 시행마다 tests/failures/errors를 읽어 기록한다
done
```

**시행마다 결과 파일을 지우고, 시행 뒤 실제로 돌았는지 확인한다.** 캐시로
건너뛴 실행을 초록으로 세면 그것 자체가 헛통과다.

> **실패 메시지를 콘솔로 찍지 마라.** 단언 문구에 한글이 섞이면 Windows 콘솔
> (cp949)에서 집계 스크립트가 죽는다. 이 세션에서 세 명이 여기 걸려 실패 원인을
> 놓쳤다. 결과 XML을 **UTF-8 파일로** 뽑아 읽는다.

| 볼 것 | 기준 |
|---|---|
| 각 커밋 시점에 테스트가 통과했나 | 커밋을 하나씩 체크아웃해 `test`를 돌려본다. 커밋이 많으면 최소 첫·중간·끝. **내 개발 환경이 아니라 팀원의 환경으로 돌린다** — 선택적 환경변수를 빼고 본다. 안 그러면 내 기계에만 있는 값 때문에 멀쩡한 커밋이 빨갛게 보인다(실제로 겪었다) |
| 한 줄짜리 커밋이 있나 | 의미 없는 쪼개기 |
| 기능 전체가 한 커밋인가 | 리뷰 불가능한 뭉치 |
| 메시지가 "그리고"로 이어지나 | 목적이 둘 이상 섞였다 |

### 3. TDD

```bash
git log --oneline --name-only "$BASE"..HEAD
```
커밋마다 테스트 파일과 구현 파일이 함께 있나. 구현만 있는 커밋이 있으면
테스트 없이 짠 것이다.

테스트가 **실제로 실패했었는지**도 본다 — 단언이 없거나 `isNotNull()`만
있는 테스트는 처음부터 통과했을 것이다.

### 4. 주석

바뀐 코드의 주석을 읽는다.

- "왜"가 있나. 코드가 이미 말하는 "무엇"을 반복하고 있지 않나
- 함정·제약·의도적 선택이 기록됐나
- 설명이 코드보다 길지 않나

### 5. SOLID

- 한 클래스가 한 가지 이유로만 바뀌나
- 의존 방향이 한쪽인가
- **구현이 하나뿐인 인터페이스를 만들지 않았나** (과잉설계도 위반이다)

### 6. 문서 — README(커밋됨) · CLAUDE.md(안 됨)

**여기서 보는 것은 `README.md`다.** `CLAUDE.md`는 커밋되지 않아 지금 안 고쳐도
PR이 늦어지지 않지만, README는 **이 PR에 못 태우면 PR이 하나 더 필요해진다.**

#### 6-1. README가 이번 변경을 반영하나

이번 PR이 **밖에서 보이는 것**을 바꿨으면 README도 바뀌어야 한다.

```bash
# 새로 생긴 엔드포인트가 문서에 있나
git diff "$BASE"..HEAD -- '*.java' | grep -E '^\+.*@(Get|Post|Put|Delete|Patch|Request)Mapping'

# 새로 생긴 표가 문서에 있나
git diff --name-only --diff-filter=A "$BASE"..HEAD | grep -E 'db/migration/.*\.sql'

# 새로 생긴 필수 환경변수가 문서에 있나
git diff "$BASE"..HEAD -- '*.yml' '*.yaml' | grep -E '^\+.*\$\{[A-Z_]+:'

# README가 이 PR에 들어 있나
git diff --name-only "$BASE"..HEAD | grep -E '(^|/)README\.md$'
```

위 셋 중 하나라도 결과가 나왔는데 **README가 diff에 없으면 근거를 대야 한다.**

| 판정 | 조건 |
|---|---|
| **PASS** | README를 같이 고쳤다 |
| **PASS** | 바꾼 것이 내부 구현뿐이라 README가 말하는 사실이 그대로다 — **무엇이 그대로인지 한 줄로 적는다** |
| **FAIL** | 위 명령에 걸렸는데 README를 안 봤다 |

특히 확인할 넷 — **팀 계약(엔드포인트 경로·이름)** · 표 소유 목록 ·
필수 환경변수 · "상태/미구현" 절. **경로 이름은 문서가 아니라 코드를 정본으로 본다.**
문서가 `verify`라 적었는데 코드가 `resolve`면 문서가 틀린 것이다.

#### 6-2. CLAUDE.md는 맞는 층에 갔나

새로 생긴 도메인 사실·결정·함정이 **맞는 층**에 갔나.

| 무엇 | 어느 층 |
|---|---|
| 모듈의 도메인 규칙·함정 | 3층 `<모듈>/CLAUDE.md` |
| 브랜치 전략·스택·모듈 인덱스 | 2층 `<repo>/CLAUDE.md` |
| 하네스 변경 이력 | 2층 변경 이력 표 |

상위 층에 상세를 몰아쓰지 않았나. **마무리는 Phase 8(`wrap`)에서 한다** —
여기서는 빠진 것이 있는지만 본다.

#### 6-3. 고친 결함이 "알려진 구멍" 목록에 남아 있지 않나

`CLAUDE.md`의 알려진 구멍 목록에서 **이번에 고친 항목을 지운다.**
고쳐 놓고 목록에 남기면 다음 세션이 이미 없는 문제를 다시 조사한다.

### 7. PR 리뷰 봇

리뷰 봇이 claudecode·codex 2개인가. 다른 봇이 붙어 있지 않나.

### 8. contributors

```bash
git log --format='%b' "$BASE"..HEAD | grep -i "co-authored-by"
```
**결과가 비어야 한다.**

### 9. AI 파일

```bash
git diff --name-only "$BASE"..HEAD | grep -E '(^|/)(\.claude/|_workspace/|_archive/|CLAUDE\.md$|AGENTS\.md$)'
```
**결과가 비어야 한다.**

### 10. 사람 계정 리뷰

이번 세션에서 `gh pr review`·`gh pr comment`를 호출한 적이 없나.
훅이 막지만 확인한다.

### 11. 알려진 결함이 남아 있나

**세션 중에 "알지만 범위 밖"으로 미룬 것을 전부 꺼낸다.** 보고서·진행 기록·
3층 `CLAUDE.md`의 알려진 구멍에 적어 둔 것들이다.

각각 아래 셋 중 하나여야 한다. **어디에도 안 걸리면 FAIL이다.**

| 판정 | 조건 |
|---|---|
| **이 PR에서 고친다** | CI를 깨거나(플레이키 포함) 리뷰어를 오해시킬 수 있으면 무조건 이쪽 |
| **사용자가 명시적으로 미루기로 했다** | 물었고 **답을 받았다.** 답이 없으면 이 칸이 아니다 |
| 운영 전 과제로 기록됐다 | 이 PR의 동작에 영향이 없고 3층 `CLAUDE.md`에 근거·숫자와 함께 있다 |

**"답이 없어서 보수적으로 미뤘다"는 통과 사유가 아니다.** 미루는 것도 결정이고
결정은 사용자가 한다. 답이 없으면 **PR을 올리지 않고 기다린다.**

판정 질문 하나로 줄이면 이것이다 —
**"이 결함 때문에 CI가 빨간불이 될 수 있나?" 그렇다면 지금 고친다.**
알면서 올리면 리뷰어는 이 PR이 깬 것으로 읽고, 그 오해를 푸는 데 라운드 하나가 나간다.
고친 뒤 push하면 봇 재리뷰가 또 한 바퀴 돈다 — **PR 전에 고치는 것이 항상 싸다.**

---
