# Panely 코드 리뷰 — 수정 체크리스트

전체 코드 리뷰(53개 Swift 파일)에서 도출된 액션 아이템.
우선순위순으로 정렬했고, 각 항목은 파일/라인 + 조치 방향까지 포함.

---

## 🔴 Critical (즉시 조치 권장)

- [ ] **`BookmarksStore.pageBookmarksByBook` 무제한 증가 방지**
  - 위치: `Panely/Features/Library/Store/BookmarksStore.swift:18, 144-147`
  - 문제: 책당/전체 페이지 북마크 상한 없음 + 삭제된 책의 entry가 영원히 남음. UserDefaults ~4MB 한계 도달 시 디코드 실패로 **전체 북마크 일괄 손실** 가능 (`load()` 73-77줄 `try?` 처리)
  - 조치:
    - [ ] 책당 페이지 북마크 상한 도입 (예: 500개)
    - [ ] Favorites/Recents에 없는 책의 entry를 주기적으로 가비지 컬렉트
    - [ ] UserDefaults 대신 별도 파일(JSON) 저장 검토

- [ ] **Stale security-scoped bookmark 재생성 누락**
  - 위치: `Panely/Features/Library/Store/RecentItemsStore.swift:57-65`, `BookmarksStore.swift:60-68`
  - 문제: `bookmarkDataIsStale` 결과를 받기만 하고 사용 안 함 → 외장 디스크에서 옮긴 책이 영원히 resolve 실패
  - 조치:
    - [ ] `resolve()`에서 stale 감지 시 즉시 새 bookmark 재생성하여 store 갱신
    - [ ] Apple 표준 패턴(stale → 재bookmark → 저장) 적용

- [ ] **`preferredColorScheme(.dark)` 강제와 라이트 모드 토큰 부재**
  - 위치: `Panely/PanelyApp.swift:15`, `Panely/DesignSystem/Tokens/PanelyColor.swift`
  - 문제: 시스템 외관 무시. 현 색상 토큰은 모두 다크 전용
  - 조치 (택1):
    - [ ] 다크 전용이 의도라면 README/Info.plist에 명시
    - [ ] 또는 `Color(light:dark:)` 페어로 토큰 재정의 후 `.preferredColorScheme` 제거

---

## 🟠 Major

- [ ] **NSCache `countLimit` / `totalCostLimit` 비대칭**
  - 위치: `Panely/Features/Reader/ViewModel/ReaderViewModel.swift:89-98`
  - 문제: `totalCostLimit = 150MB`인데 `countLimit = 10`이라 vertical 모드(window radius 3 + keep buffer 10) 들어가면 cost 여유 있는데도 LRU eviction 발생 → prefetch hit-rate 손해
  - 조치:
    - [ ] `countLimit`을 100 정도로 완화 (cost-driven eviction이 주가 되도록)

- [ ] **temp dir 정리와 첫 load 경쟁**
  - 위치: `Panely/Features/Reader/ViewModel/ReaderViewModel.swift:251-253` + `+Source.swift`의 `cleanupStaleTempDirs`
  - 문제: init의 detached cleanup이 진행 중 추출되는 `panely-*` dir을 지울 수 있음
  - 조치:
    - [ ] mtime 기준으로 N분 이상 된 dir만 삭제, 또는 dir 이름에 PID/세션 포함 (`panely-<pid>-...`)

- [ ] **경로 비교 일관성 (Favorites vs Volumes/Files)**
  - 위치: `Panely/Features/Library/LibrarySidebar.swift:~86, ~99, ~127`
  - 문제: Favorites는 `activeURL?.path == fav.path` 문자열 비교, Volumes는 `standardizedFileURL` 비교 → 심볼릭 링크/외장 디스크에서 활성 표시기 깨짐
  - 조치:
    - [ ] 모든 비교를 `standardizedFileURL`로 통일

- [ ] **`PositionKey`가 경로 변경에 취약**
  - 위치: `Panely/Features/Reader/ViewModel/ReaderViewModel+Source.swift:437-443`, `Panely/Features/Reader/Model/PositionKey.swift`
  - 문제: 외장 디스크/마운트 경로/심볼릭 링크 변경 시 다른 키 생성 → 북마크/위치/즐겨찾기 동기화 끊김
  - 조치:
    - [ ] 가능한 경우 file-id/inode 기반 fallback 추가
    - [ ] 또는 콘텐츠 해시(첫 페이지 + pageCount 등) 기반 fingerprint

- [ ] **`clampedRestoredIndex` 더블 페이지 마지막 spread 도달 불가**
  - 위치: `Panely/Features/Reader/ViewModel/ReaderViewModel+Source.swift:445-450`
  - 문제: `min(_, pageCount - 1)` 때문에 100페이지 더블 모드에서 99(마지막)에 멈출 수 없음 → 마지막 페이지 종료 후 재오픈 시 한 spread 뒤로 회귀
  - 조치:
    - [ ] step 정렬된 마지막 index까지 허용하도록 클램프 식 재검토

- [ ] **AppKit 옵저버 lifecycle 가드 약함**
  - 위치: `Panely/Features/Reader/Viewer/AppKitImageScroller.swift`, `Panely/Features/Reader/Viewer/TitleBarPassthrough.swift`
  - 문제: `updateNSView`가 여러 번 호출될 때 옵저버 재등록/중복 등록 가드 약함
  - 조치:
    - [ ] Coordinator에 등록 여부 플래그 추가
    - [ ] frame/bounds 변경 시점에 옵저버 명시 해제 후 재등록
    - [ ] `deinit` 정리 패스 재검증

---

## 🟡 Minor

- [ ] **`ComicPage.id`가 매 init마다 새 UUID → 썸네일 캐시 미스**
  - 위치: `Panely/Core/Comic/ComicPage.swift:9`, `Panely/Features/Reader/Thumbnails/ThumbnailLoader.swift:32`
  - 조치:
    - [ ] `page.id`를 결정적 값으로 변경 (`source kind + path`)
    - [ ] 또는 `ThumbnailLoader` 캐시 키를 `(source, maxPixelSize)`로 변경

- [ ] **CBZ 추출 시 zip-bomb / 디스크 가드 부재**
  - 위치: `Panely/Core/Comic/CBZLoader.swift:44-53`
  - 문제: ZIPFoundation 0.9.20+이라 path traversal은 라이브러리 단에서 차단되지만 총 추출 크기 제한이 없음
  - 조치:
    - [ ] 누적 추출 바이트 모니터링 후 임계(예: 5GB)에서 중단

- [ ] **`RecentItemsStore.record`의 reopen 분기에서 stale 검사 누락**
  - 위치: `Panely/Features/Library/Store/RecentItemsStore.swift:19-26`
  - 조치:
    - [ ] reopen 빠른 경로에서도 `bookmarkDataIsStale` 검사 + 필요 시 재생성

- [ ] **`QuickJumpField` 포커스 race**
  - 위치: `Panely/Features/Reader/Toolbar/QuickJumpField.swift:~69`
  - 조치:
    - [ ] `DispatchQueue.main.async` 제거하고 `@FocusState`로 전환

- [ ] **`LoadingOverlay.allowsHitTesting(false)` — 로딩 중 입력 통과**
  - 위치: `Panely/Features/Reader/Overlays/LoadingOverlay.swift:29`
  - 조치:
    - [ ] 의도라면 주석 명시, 아니면 hit-testing 켜고 배경 클릭 무시 핸들러 추가

- [ ] **`PanelyIconButton` 접근성 라벨 / 히트 타깃**
  - 위치: `Panely/DesignSystem/Primitives/PanelyIconButton.swift`
  - 조치:
    - [ ] `.accessibilityLabel()` 추가 (현재 `.help()` 툴팁만 있음)
    - [ ] 히트 타깃 32×32 → 44×44 검토 (HIG)

- [ ] **`PanelySlider` drag end 스냅 없음**
  - 위치: `Panely/DesignSystem/Primitives/PanelySlider.swift`
  - 조치:
    - [ ] `DragGesture.onEnded`에서 정수 페이지로 스냅

---

## ⚪ Nit

- [ ] **`PanelyApp.panelyCommands` 길이 분리**
  - 위치: `Panely/PanelyApp.swift:24-184`
  - 조치:
    - [ ] 메뉴별 `Commands` 타입으로 추출 (`FileCommands`, `ViewCommands`, `GoCommands`)

- [ ] **`EndOfVolumeCard` / `PreviousVolumeCard` 머티리얼·섀도우 중복**
  - 위치: `Panely/Features/Reader/Overlays/EndOfVolumeCard.swift`, `PreviousVolumeCard.swift`
  - 조치:
    - [ ] 공통 `VolumeNavigationCard` 컴포넌트로 추출

- [ ] **자연 정렬 로직 중복**
  - 위치: `Panely/Core/Comic/CBZLoader.swift:17-19`, `FolderLoader.swift` 유사 부분
  - 조치:
    - [ ] `NaturalSort` 헬퍼로 일원화 (테스트는 이미 존재)

- [ ] **Info.plist UTI 표준 conformsTo 누락**
  - 위치: `Info.plist`
  - 조치:
    - [ ] 커스텀 `com.panely.cbz`에 `public.zip-archive`, `public.archive` 등 표준 UTI conformsTo 추가 → Finder/Spotlight 인식 ↑

- [ ] **이미지 cost 계산 정밀도**
  - 위치: `Panely/Features/Reader/ViewModel/ReaderViewModel+ImageLoading.swift` (cost 계산부)
  - 조치:
    - [ ] HDR/16비트 이미지 고려 (현재 `area × 4` 고정)

---

## 우선순위 요약

1. Critical 1 (북마크 용량 상한·GC) — 데이터 손실 방지
2. Critical 2 (stale bookmark 재생성) — UX 회귀 방지, 1과 함께 처리
3. Critical 3 (다크모드 결정 명시) — 의도 문서화 or 토큰 분리
4. Major 1 (NSCache countLimit) — vertical hit-rate 즉시 개선
5. Major 6 (AppKit 옵저버 lifecycle) — 잠재 누수 방어
6. Major 3 (경로 정규화 통일) — 외장 디스크 사용자 영향
