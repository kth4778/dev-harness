## 이 프로젝트의 함정

### Testcontainers는 싱글톤으로 공유한다

`@Testcontainers`/`@Container`를 쓰면 **클래스마다 컨테이너를 멈춘다.**
그런데 스프링은 ApplicationContext를 캐시해 재사용하므로, 두 번째 테스트
클래스가 이미 죽은 커넥션을 잡는다.

```java
@SpringBootTest
public abstract class PostgresTestBase {
    // @Testcontainers/@Container를 쓰지 않는다 — 위 이유 때문
    static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16");
    static { POSTGRES.start(); }

    @DynamicPropertySource
    static void 데이터소스(DynamicPropertyRegistry registry) {
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
    }
}
```

### 동시성은 시작선을 맞춰야 검증된다

스레드를 그냥 띄우면 실행이 직렬화되어 **경합 없이 둘 다 성공**한다.
그러면 버그가 있어도 테스트가 통과한다.

```java
CountDownLatch 준비 = new CountDownLatch(2);
CountDownLatch 시작선 = new CountDownLatch(1);
// 워커: 준비.countDown() → 시작선.await() → 작업
준비.await();          // 둘 다 시작선 앞에 섰는지 확인하고
시작선.countDown();    // 그때 푼다
```

예상 밖 예외는 워커 안에서 삼켜진다. `Future.get()`으로 꺼내야 테스트 실패로 드러난다.

### 메이저 버전이 바뀌면 패키지가 옮겨간다

의존성 좌표가 맞아도 `import` 경로가 틀리면 컴파일이 안 된다.
새 라이브러리는 **좌표와 패키지 경로를 둘 다** 실물로 확인한다.
