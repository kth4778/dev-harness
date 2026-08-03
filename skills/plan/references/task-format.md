## 태스크 형식

````markdown
### 태스크 N: {이름}

**파일**
- 생성: `정확한/경로/File.java`
- 수정: `정확한/경로/Other.java:123-145`
- 테스트: `정확한/경로/FileTest.java`

**인터페이스**
- 받는 것: {앞 태스크가 만든 것 — 정확한 시그니처}
- 주는 것: {뒤 태스크가 쓸 것 — 정확한 이름·타입}

- [ ] **1단계: 실패하는 테스트를 쓴다**

```java
@Test
void 검색어가_비어있으면_예외가_발생한다() {
    assertThatThrownBy(() -> cardService.search(""))
        .isInstanceOf(InvalidSearchException.class);
}
```

- [ ] **2단계: 실패를 확인한다**

실행: `./gradlew :clip:test --tests "CardServiceTest"` (빌드 루트에서. 모노레포면 그 폴더로 먼저 이동)
예상: FAIL — 컴파일 오류 또는 단언 실패. **실패 이유가 의도한 이유인지 본다**

- [ ] **3단계: 최소 구현**

```java
public List<Card> search(String keyword) {
    if (keyword.isBlank()) throw new InvalidSearchException();
    return cardRepository.findByNameContaining(keyword);
}
```

- [ ] **4단계: 통과 확인**

실행: `./gradlew :clip:test --tests "CardServiceTest"` (빌드 루트에서. 모노레포면 그 폴더로 먼저 이동)
예상: PASS

- [ ] **5단계: 커밋**

```bash
git add clip/src/test/... clip/src/main/...
git commit -m "feat: 빈 검색어 예외 처리"
```
````
