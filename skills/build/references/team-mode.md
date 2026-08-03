## 팀 모드로 돌릴 때

`harness-design`이 팀 모드나 하이브리드를 골랐으면 이렇게 돈다.

### 도구

**`TeamCreate`는 없다.** 이 세션에는 암묵적 팀이 하나 있고, `name`을 준
에이전트가 자동으로 들어간다.

```
Agent({ name: "spring-implementer", subagent_type: "spring-implementer",
        run_in_background: true, prompt: "..." })

SendMessage({ to: "code-critic", summary: "태스크3 리뷰 요청",
              message: "..." })
```

`name`을 안 주면 부를 수 없다. 이름은 에이전트 정의 파일명과 같게 한다.

### 팀원끼리 직접 왕복시킨다

팀 모드의 이점은 여기서 나온다. 리뷰 지적을 내가 받아서 구현자에게 전달하면
서브에이전트와 다를 게 없다. **리뷰어가 구현자에게 직접 보내게 한다.**

```
구현자 ──SendMessage──> 리뷰어 : "태스크3 끝났다. 파일 X, Y"
리뷰어 ──SendMessage──> 구현자 : "중대 1건 — Z에서 null 가능"
구현자 ──SendMessage──> 리뷰어 : "고쳤다. 재검토 요청"
리뷰어 ──SendMessage──> main   : "태스크3 합격"
```

나는 `TaskList`로 진행만 본다. 막힌 팀원이 있으면 그때 개입한다.

### 공유 작업 목록

```
TaskCreate({ subject: "태스크3: 로그인 서비스", description: "..." })
TaskUpdate({ owner: "spring-implementer", status: "in_progress" })
```

팀원이 자기 상태를 갱신하고, 나는 `TaskList`로 전체를 본다.
팀원이 유휴 상태가 되면 자동으로 알림이 온다.

### 구현자는 여전히 한 명씩

**팀 모드라도 구현자를 병렬로 돌리지 않는다.** 같은 파일을 건드려 충돌한다.
병렬로 돌릴 수 있는 것은 보는 파일이 다른 역할이다 — 검증자와 코드 검토자는
최종 단계에서 동시에 띄워도 된다.

### 서브에이전트 모드면

`SendMessage` 없이 `Agent` 반환값만 받는다. 아래 절차는 두 모드 공통이다.
