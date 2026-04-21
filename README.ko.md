<p align="center">
  <img src="docs/icon/panely-icon-stacked.svg" width="160" alt="Panely">
</p>

<h1 align="center">Panely</h1>

<p align="center">
  macOS를 위한 미니멀하고 빠른 만화/이미지 뷰어.<br>
  <em>A minimal, fast comic &amp; image viewer for macOS.</em>
</p>

<p align="center">
  <a href="README.md">English</a> · <strong>한국어</strong>
</p>

<p align="center">
  <img alt="platform" src="https://img.shields.io/badge/platform-macOS%2014%2B-blue">
  <img alt="swift" src="https://img.shields.io/badge/swift-5-orange">
  <img alt="license" src="https://img.shields.io/badge/license-Apache%202.0-green">
  <a href="https://github.com/sejoung/Panely/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/sejoung/Panely/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://github.com/sejoung/Panely/actions/workflows/release.yml"><img alt="Release" src="https://github.com/sejoung/Panely/actions/workflows/release.yml/badge.svg"></a>
  <a href="https://github.com/sejoung/Panely/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/sejoung/Panely?label=latest&color=brightgreen"></a>
  <a href="https://github.com/sejoung/Panely/releases/latest"><img alt="Release date" src="https://img.shields.io/github/release-date/sejoung/Panely?color=blue"></a>
  <a href="https://github.com/sejoung/Panely/releases"><img alt="Total downloads" src="https://img.shields.io/github/downloads/sejoung/Panely/total?color=brightgreen"></a>
</p>

---

## 개요

Panely는 사용자를 방해하지 않는 만화 리더입니다. 필요 없을 때는 UI가
사라지고, 사이드바는 필요할 때만 나타나며, 뷰어는 항상 최대 공간을 차지합니다.
밝은 크롬에서 읽는 건 피로하므로 다크 모드가 기본 고정입니다.

뷰어 코어는 AppKit 기반(`NSScrollView` + 레이어 기반 이미지 뷰)으로, 큰 페이지에서도
핀치 줌, 스크롤, 재정렬이 네이티브 수준으로 부드럽게 동작합니다.

## 기능

### 읽기
- **단일 페이지**, **두 페이지 펼침**, **세로 스크롤**(웹툰) 레이아웃 —
  툴바 버튼으로 `single → double → vertical → single` 순환
- **좌→우** 또는 **우→좌** 읽기(만화 친화). 세로 모드에서는 RTL 무시
  (웹툰은 위→아래), 방향 토글 자동 비활성화
- **세 가지 맞춤 모드** — 고유 화살표 아이콘과 `⌘1`/`⌘2`/`⌘3` 단축키:
  - **화면에 맞춤** — 페이지 전체가 보이도록
  - **가로에 맞춤** — 뷰포트 가로에 맞춤
  - **세로에 맞춤** — 뷰포트 세로에 맞춤
- **세로 모드 지연 윈도잉** — 페이지 크기를 미리 가져와서(폴더는 헤더만)
  회색 플레이스홀더로 즉시 레이아웃을 잡은 뒤, 보이는 범위의 실제 이미지를
  동시 로드하고 배치된 SwiftUI 패스로 업데이트 (이미지마다 재레이아웃 폭주 방지)
- **줌 컨트롤** — `⌘+` / `⌘-` / `⌘0`(맞춤으로 리셋) + 툴바 버튼.
  `⌘ + 스크롤 휠`은 커서 중심으로 연속 줌(스크롤 단위당 ~1%).
  트랙패드 핀치, 더블클릭 1× ↔ 2× 그대로
- **뷰 크기 잠금(`⌘L`)** — 창/사이드바 리사이즈와 레이아웃 전환 사이에서
  현재 배율을 고정하는 opt-in 토글. 강제 리셋(새 책, 명시적 `⌘1`/`⌘2`/`⌘3`)은
  여전히 적용됨
- **뷰포트 리사이즈 시 자동 재맞춤**(잠금 해제 시) — 창이나 사이드바 크기가
  바뀌면 새 맞춤으로 스냅. 수동 줌은 기본으로 보존
- **자동 센터링** — 뷰포트가 더 클 때 이미지를 중앙에 유지
- **±2페이지 프리로드**(페이지 모드) — 다음 페이지 전환이 즉시 체감
- **진행 오버레이** — 큰 소스를 처리하는 동안 단계별 메시지
  (Opening / Extracting / Loading / Building vertical strip), 전부 백그라운드 스레드

### 파일 지원
- **폴더**, **CBZ**, **ZIP** 열기
- **시리즈 루트 자동 감지** — 볼륨들이 들어있는 폴더를 고르면 첫 번째가 열림
- **중첩 아카이브 추출**(최대 3단계 재귀)
- 자연 파일명 정렬(`1, 2, 10` — `1, 10, 2` 아님)
- 비이미지 파일과 숨김 항목 필터링

### 네비게이션
- **키보드 우선** — `← → Space` 페이지, `⌘[ ⌘]` 볼륨,
  `⌘1 ⌘2 ⌘3` 맞춤 모드, `⌘+ ⌘- ⌘0` 줌, `⌃⌘S` 사이드바 고정,
  `⌃⌘T` 툴바 고정, `⌘L` 뷰 크기 잠금, `⌘O` 열기
- **라이브러리 사이드바 자동 숨김** — 기본으로 숨겨서 페이지에 최대 공간
  제공. **왼쪽 가장자리**에 호버(200 ms) 시 오버레이로 슬라이드 인
  (드롭 섀도, 페이지 시프트 없음). 마우스 나가면 300 ms 후 자동 해제,
  `ESC`는 즉시 해제
- **툴바 + 슬라이더 자동 숨김** — 뷰어 상/하단 근처에 커서 있을 때만
  플로팅. `⌃⌘T`(또는 고정 버튼)로 항상 표시
- **사이드바 / 툴바 고정** — 둘 다 `pin` ↔ `pin.fill` 토글 패턴. 고정
  상태는 실행 간 유지
- **사이드바 트리** — 폴더와 아카이브가 시각적으로 구분됨:
  `folder` vs `doc.zipper` 아이콘, 아카이브엔 빠른 식별용으로 희미한
  `.cbz` / `.zip` 접미사
- **세로 모드 페이지 네비게이션** — `← → Space`로 스트립에서 이전/다음
  이미지로 스크롤(키보드로 마지막 이동한 위치가 아니라 현재 뷰포트 중앙에
  있는 페이지 기준)
- 같은 폴더의 형제 책 간 **볼륨 네비게이션**
- **최근 항목** — security-scoped bookmark로 실행 간 유지, 동일한
  아이콘 스킴으로 표시
- **폴더 접근 허용** — 단일 파일을 열었고 형제 책들이 안 보일 때,
  사이드바에서 상위 폴더를 고를 수 있는 원클릭 프롬프트 제공
- **창 컨트롤** — 타이틀바가 숨겨진 상태에서도 상단 28 px 스트립에서
  네이티브 드래그 이동과 더블클릭 확대(시스템 `AppleActionOnDoubleClick`
  환경설정 존중) 지원. 드래그 영역은 open-hand 커서로 표시

### 상태 유지
- **읽던 위치에서 이어보기** — 임시 디렉터리 추출을 버티는 안정적인 키로
  책별 페이지 기억
- **레이아웃 + 방향 + 맞춤 모드 + 사이드바 고정 + 툴바 고정 + 자동 맞춤
  잠금** 모두 유지(레거시 `panely.sidebarVisible` 키는 새 고정 플래그로
  자동 마이그레이션)
- 완전 샌드박스 호환(사용자 선택 파일 + 앱 스코프 북마크)

## 요구 사항

- **macOS 14** (Sonoma) 이상
- **Xcode 16** 이상 (소스 빌드 시)

## 시작하기

```bash
git clone https://github.com/sejoung/Panely.git
cd Panely
open Panely.xcodeproj
```

**Panely** 스킴을 선택하고 **⌘R**을 눌러 실행.

### 의존성

Panely는 Swift Package Manager를 사용합니다. 외부 의존성은 하나뿐:

- **[ZIPFoundation](https://github.com/weichsel/ZIPFoundation)** — CBZ/ZIP 아카이브 읽기 및 추출

Xcode가 첫 빌드에서 자동 해결합니다.

## 단축키와 제스처

| 입력 | 동작 |
|:------|:-------|
| `⌘O` | 폴더 / CBZ / ZIP 열기 |
| `←` / `→` | 이전 / 다음 페이지 (페이지 모드는 방향 반영, 세로 모드는 이미지 단위) |
| `Space` | 다음 페이지 (세로 모드에선 다음 이미지로 스크롤) |
| `⌘[` / `⌘]` | 이전 / 다음 볼륨 |
| `⌘G` | 페이지 번호로 이동… (모달 프롬프트) |
| `⌘D` | 페이지 북마크 추가 / 제거 |
| `⌘⇧D` | 현재 책 즐겨찾기 추가 / 제거 |
| `⌘⇧[` / `⌘⇧]` | 현재 책의 이전 / 다음 페이지 북마크로 이동 |
| `⌘1` / `⌘2` / `⌘3` | 화면 맞춤 / 가로 맞춤 / 세로 맞춤 |
| `⌘+` / `⌘-` | 줌 인 / 아웃 (뷰포트 중심, 한 단계) |
| `⌘0` | 현재 맞춤 모드로 줌 리셋 |
| `⌘ + 스크롤 휠` | 커서 중심 연속 줌 |
| `⌘L` | 뷰 크기 잠금 / 해제 (리사이즈와 레이아웃 전환 시 줌 유지) |
| `⌃⌘S` | 라이브러리 사이드바 고정 / 해제 |
| `⌃⌘T` | 툴바(하단 슬라이더 포함) 고정 / 해제 |
| `⌃⌘P` | 썸네일 사이드바 표시 / 숨김 |
| 왼쪽 가장자리 호버 | 사이드바 오버레이로 나타냄 (자동 숨김 모드에서) |
| `ESC` | 사이드바 오버레이 해제 (고정 안 된 상태) |
| 이미지 위 더블클릭 | 1× ↔ 2× 줌 토글 |
| 트랙패드 핀치 | 줌 인 / 아웃 |
| 상단 28 px 스트립 드래그 | 창 이동 |
| 상단 28 px 스트립 더블클릭 | 창 확대 / 최소화 (시스템 환경설정에 따름) |

## 테스트

```bash
xcodebuild test \
  -project Panely.xcodeproj \
  -scheme Panely \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-"
```

**33 스위트에 걸친 168개 테스트**가 다음을 커버:

- 순수 데이터 타입 (`ComicPage`, `ComicSource`, `RecentItem`, enum raw 값)
- 자연 정렬 규약 (Panely가 의존하는 Foundation 동작)
- 임시 디렉터리 추출(중첩 zip 시나리오)에서의 **위치 키 안정성**
- 실제 임시 디렉터리와 통합한 **FolderLoader**
- **FileNode.loadTree** 스캔, 정렬, 비어있음/읽기 불가 케이스, 사이드바 배지용
  `fileExtension` 노출
- 프로그래매틱하게 만든 zip 픽스처와의 **CBZLoader** 통합 — 재귀 중첩 아카이브
  추출 포함
- **ImageLoader.dimensions** — 파일 URL과 아카이브 엔트리 모두 헤더만 읽어 크기 추출
- **FitCalculator** 다양한 종횡비와 0 입력에 대한 순수 계산 (세로 소스에서
  fit-height가 fit-screen과 동일해지는 케이스 포함)
- 반복된 맞춤 모드 토글에 대한 **NSScrollView** 배율 안정성
- **뷰어 리사이즈 자동 맞춤** — 줌 안 했을 때 뷰포트 따라가고, 리사이즈 시 수동 줌
  보존, `⌘L` 잠금은 문서 크기 변경에도 유지, 강제는 여전히 리셋, deinit에서 옵저버 해제
- **CenteringClipView** — 문서가 뷰포트보다 작을 때 중앙 정렬
- **SidebarMode** — pinned / overlay 상태 전이를 다루는 순수 값 타입
  (기본 unpinned, pin 멱등, pinned 중 overlay no-op, unpin 시 남아있는
  overlay 정리)
- **PageLayout 순환** — `single → double → vertical → single` 순서,
  모드별 `navigationStep`, 세로용 `isContinuous` 플래그
- **`ReaderViewModel` 페이지 모드 동작** — `visiblePages` 슬라이싱,
  세로 모드 외에서 `setCurrentPageFromScroll` no-op, 페이지 모드에서
  `toggleDirection` 동작
- **`ReaderViewModel` 세로 모드 동작** — `visiblePages`가 전체 스트립 반환,
  `setCurrentPageFromScroll` 인덱스 업데이트, `effectiveDirection`은
  항상 LTR, 페이지→세로 전환 시 로딩 인디케이터 즉시 표시, applyFit이
  맞춤 계산에 첫 이미지 사용
- **`ImageStackView` 세로 레이아웃** — `pageIndex(forViewportY:)`,
  `pageIndexRange(visibleIn:)`, 개수+축 일치 시 `setImages`의 점진적 교체
  (뷰 재빌드 없음) vs 축 변경 시 전체 재빌드
- 최소/최대 클램핑과 함께 `NSScrollView` 대상 **`ViewerController`** 줌 인/아웃/리셋
- **`ScrollZoomCalculator`** — 스크롤 휠 delta에서 min/max 클램프한 곱셈형
  줌 팩터 계산
- **툴바 고정 상태** — 기본 unpinned, 토글이 저장된 플래그를 뒤집음
- **썸네일 사이드바 토글** — 기본 숨김, `toggleThumbnailSidebar`가 저장된
  플래그를 뒤집음
- **Quick-jump 계산** — 단일+이중 레이아웃에서 `currentPageNumber` /
  `currentPageRangeEndNumber`, `jump(toPageNumber:)`는 범위 밖 입력 클램프 및
  이중 모드에서 네비게이션 step에 스냅
- **`BookmarksStore` 페이지 북마크** — 토글 추가/제거, 키 격리, 페이지
  인덱스로 정렬, next/previous 네비게이션, ID로 제거, `UserDefaults` 영속성
  왕복
- **`BookmarksStore` 즐겨찾기** — 실제 임시 파일에 대한 토글 추가/제거,
  security-scoped 북마크가 원래 URL로 resolve
- **`FavoriteBook` / `PageBookmark` Codable** — 왕복 충실도 + `isDirectory`
  없는 레거시 `FavoriteBook` JSON의 forward-compat 디코드
- **`ReaderViewModel` 북마크 가드** — 소스 미로드 시 `toggle*`,
  `canGo*Bookmark`, `currentPositionKey`가 no-op / false / nil
- **`ThumbnailLoader`** — 접근 불가 URL은 nil, 실제 PNG는 non-nil, 동일
  `ComicPage.id`는 `===`로 캐시된 `NSImage` 반환, 서로 다른 페이지는 별개 캐시 엔트리
- **`PanelyAppDelegate`** — `applicationShouldTerminateAfterLastWindowClosed`가
  true 반환해서 빨간 닫기 버튼이 앱 종료

테스트는 소스 트리를 그대로 반영해 `PanelyTests/Core/`,
`PanelyTests/Features/Library/`, `PanelyTests/Features/Reader/` 아래에
조직되어 있고, 공유 픽스처(실제 PNG 생성기 포함)는
`PanelyTests/TestFixtures.swift`에 있습니다.

`RecentItem.Codable`은 `isDirectory`용 `decodeIfPresent` 경로를 포함하여
오래된 저장 엔트리가 스키마 범프를 넘어 살아남습니다.

## 프로젝트 구조

```
Panely/
├── PanelyApp.swift                     # @main, 커맨드, 윈도우 스타일
├── ContentView.swift
├── AppIcon.icns                        # docs/icon/*.svg에서 생성
├── DesignSystem/
│   ├── Tokens/                         # Color / Spacing / Typography / Motion
│   └── Primitives/                     # 아이콘 버튼, 슬라이더
├── Features/
│   ├── Reader/
│   │   ├── ReaderViewModel.swift       # @Observable @MainActor — 저장 프로퍼티 + init
│   │   ├── ReaderViewModel+Navigation.swift  # 페이지 네비, Quick jump, chrome 토글
│   │   ├── ReaderViewModel+Source.swift      # 소스 로딩, 볼륨 네비, 위치 기억
│   │   ├── ReaderViewModel+ImageLoading.swift # 프리로드, 세로 지연 윈도우, 캐시
│   │   ├── ReaderViewModel+Bookmarks.swift   # 즐겨찾기/페이지 북마크 연동
│   │   ├── ReaderScene.swift           # ZStack 레이아웃 + 핫엣지 호버
│   │   ├── ViewerContainer.swift       # SwiftUI 셸 + AppKitImageScroller
│   │   │                               # (뷰 재사용하는 ImageStackView)
│   │   ├── ViewerController.swift      # 줌 리모트 (⌘+/-/0, 스크롤 휠)
│   │   ├── PanelyToolbar.swift         # 레이아웃 순환 / 맞춤 / 줌 / 고정 / ★ / 🔖 버튼
│   │   ├── QuickJumpField.swift        # 페이지 카운터 인라인 편집
│   │   ├── ThumbnailSidebar.swift      # 우측 썸네일 패널 (LazyVStack)
│   │   ├── ThumbnailLoader.swift       # Image I/O 썸네일 + NSCache
│   │   ├── LoadingOverlay.swift
│   │   ├── PageLayout.swift            # single/double/vertical + 순환 + isContinuous
│   │   ├── ReadingDirection.swift / FitMode.swift  # FitMode: 3가지 + 순환
│   │   ├── FitCalculator.swift         # 순수 배율 계산
│   │   ├── PositionKey.swift           # 책별 안정적 위치 키
│   │   └── SidebarMode.swift           # pinned / overlay 상태 값 타입
│   └── Library/
│       ├── LibrarySidebar.swift        # 고정 버튼 + 확장자 배지 + 2단계 로드
│       ├── FileNode.swift              # iconName + fileExtension + 최상위 병렬 스캔
│       ├── RecentItem.swift / RecentItemsStore.swift  # 재열기 시 북마크 중복 제거
│       ├── FavoriteBook.swift / PageBookmark.swift    # 영속 북마크 데이터 타입
│       └── BookmarksStore.swift        # 즐겨찾기 + 페이지 북마크 영속 저장소
└── Core/
    └── Comic/
        ├── ComicPage.swift / ComicSource.swift / ComicPageSource.swift
        ├── FolderLoader.swift
        ├── CBZLoader.swift             # 평면 + 재귀 중첩 추출
        ├── ArchiveReader.swift         # ZIPFoundation.Archive 감싼 actor
        │                               # (헤더 전용 읽기용 loadDataPrefix)
        └── ImageLoader.swift           # async NSImage + dimensions(for:) 헤더 읽기

PanelyTests/
├── TestFixtures.swift                  # 공유 temp-dir / zip / PNG 헬퍼
├── PanelyAppDelegateTests.swift        # 창 닫으면 앱 종료 검증
├── Core/Comic/                         # ComicModel, Loader extension, FolderLoader,
│                                       # CBZLoader, ImageLoaderDimensions
├── Features/Library/                   # RecentItem, FileNode, FavoriteBook,
│                                       # PageBookmark, BookmarksStore
└── Features/Reader/                    # enums, NaturalSort, PositionKey, FitCalculator,
                                        # FitMagnificationStability, CenteringClipView,
                                        # ViewerResizeFit, SidebarMode, ViewerController,
                                        # ScrollZoomCalculator, ImageStackVertical,
                                        # ReaderViewModelPagedMode / VerticalMode,
                                        # ReaderViewModelToolbarPin / Bookmarks /
                                        # QuickJump / ThumbnailSidebar, ThumbnailLoader

docs/
├── panely_design_system_mac_os.md
└── icon/panely-icon-stacked.svg

scripts/
├── generate-app-icon.sh                # SVG → .icns 파이프라인
└── release.sh                          # 버전 범프 + 태그 + 푸시 자동화

.github/workflows/
├── ci.yml                              # push/PR에서 빌드 + 테스트
└── release.yml                         # v* 태그에서 zip + GitHub Release

Info.plist                              # 번들 아이콘 참조
Panely.entitlements                     # 샌드박스 + 사용자 선택 + 북마크
```

## 아키텍처 노트

- **`@Observable` + `@MainActor`** — `ReaderViewModel`은 메인 액터 격리
  상태로 async 로드를 지휘하며, 로딩 오버레이를 위한 명시적 단계 메시지를
  보냅니다. 클래스 본체는 저장 프로퍼티와 init만 두고, 로직은 관심사별
  extension으로 분할되어 있습니다 (`+Navigation`, `+Source`,
  `+ImageLoading`, `+Bookmarks`).
- **`nonisolated` 코어 타입** — `ComicPage`, `FolderLoader`, `CBZLoader`,
  `ImageLoader`, `FitCalculator`, `PositionKey`는 `Task.detached`로
  메인 스레드 밖에서 실행.
- **`actor ArchiveReader`** — ZIPFoundation의 `Archive`를 감싸 순차적,
  스레드 안전한 엔트리 읽기 제공.
- **AppKit 뷰어 코어** — `ViewerContainer`는 SwiftUI지만 스크롤 가능한 줌
  스테이지는 `NSScrollView` + `CenteringClipView` + 커스텀 `ImageStackView`를
  감싼 `NSViewRepresentable`. `acceptsFirstResponder`를 꺼두어 키보드
  이벤트가 SwiftUI의 `.onKeyPress`로 흘러감.
- **`CenteringClipView`**는 `constrainBoundsRect(_:)`를 오버라이드하여
  뷰포트가 더 클 때 문서를 중앙에 둠 — 사이드바 토글 시 이미지 중심 유지.
- **`TitleBarPassthrough`** — 뷰어 상단 28 px에 얹는 얇은 NSView.
  `mouseDownCanMoveWindow = true`로 네이티브 창 드래그,
  `NSTrackingArea`를 신호등 영역 외부에만 걸어 open-hand 커서가
  close/minimize/zoom 버튼 위에 새지 않도록 함, `mouseDown` 오버라이드에서
  `AppleActionOnDoubleClick`에 따라 더블클릭 줌 처리. `.hiddenTitleBar`
  아래에서 실제 창 가장자리와 정렬되도록 `.ignoresSafeArea(edges: .top)`
  사용.
- **`FitCalculator`** — 물리 뷰포트(`scrollView.contentSize`)가 배율
  불변이라서, 맞춤 모드 토글이 안정적인 배율을 생성(피드백 루프 없음).
- **리사이즈 시 뷰어 자동 재맞춤** — `AppKitImageScroller`가 자신의
  `NSScrollView` `frameDidChangeNotification`을 구독. 핸들러는
  `MainActor`로 훅 걸고 맞춤을 재계산하며, 사용자가 수동 줌을 안 했고
  뷰 크기 잠금이 꺼져 있을 때만 배율을 씀. `applyFit`은 `force` 플래그를
  분해: identity(새 책)나 fitMode 변경은 강제 리셋, 레이아웃 전용 변경은
  잠금+줌 상태에 따름.
- **세로(웹툰) 지연 윈도잉** — 세로 모드 진입 시 모든 페이지의 픽셀
  크기를 동시에 미리 가져옴(헤더만 `CGImageSource` 읽기. 아카이브 엔트리는
  `ArchiveReader.loadDataPrefix(maxBytes: 64 KB)`로 ZIPFoundation 추출을
  조기 중단해 너비/높이만 읽기 위해 엔트리 전체를 압축 해제 안 함).
  크기 페치와 디코드 둘 다 `min(8, cores)`로 제한된 청크 `withTaskGroup`으로
  실행해 큰 폴더에서 cooperative pool을 날려버리지 않음.
  `currentImages`는 같은 크기의 회색 플레이스홀더 `NSImage`로 채워지고
  (지연 `drawingHandler` — 즉시 비트맵 없음), bounds 옵저버가
  `setVisibleRange(...)`를 발화해 보이는 범위 + 버퍼의 실제 이미지를 로드.
  결과는 태스크당 **한 번의 배치 assignment**로 `currentImages`에 커밋 —
  N번이 아니라 청크당 1번의 SwiftUI 렌더. visible 범위가 다시 바뀌면
  in-flight 태스크들이 취소되고, `ImageLoader.load`가 페치와 디코드 사이에
  취소를 체크하여 버려진 작업이 즉시 중단됨.
- **윈도우 eviction** — 가시 범위가 이동하면 `[range ± 10]` 밖 페이지가
  플레이스홀더로 돌아가 1000페이지 스트립이 모든 디코드된 이미지를
  메모리에 고정하지 않음. 최근 eviction된 페이지는 스크롤 백 시 보통
  `NSCache`에서 즉시 복원.
- **`ImageStackView` 뷰 재사용** — 스택은 모든 페이지의 `pageFrames`를
  저장(모든 geometry 쿼리를 구동)하지만 실제 `NSImageView` 인스턴스는
  프레임이 보이는 뷰포트 ± 뷰포트 1개 버퍼와 겹치는 페이지만 생성.
  작은 `viewPool`(cap 24)이 재활용 뷰를 캐시해 스크롤 시 할당/해제
  churn 방지. 1000페이지 스트립이 1000개가 아니라 ~10–15개의 NSImageView
  트리에 살게 됨. `setImages` 빠른 경로(카운트+축 일치)는 라이브 뷰에 대해
  `imageView.image`만 변경하므로 페이지별 지연 로드가 포인터 쓰기 하나씩
  비용.
- **`ViewerController`** — `@Observable @MainActor` 리모트 컨트롤이며
  `PanelyApp`이 소유하고 environment로 공유. weak `NSScrollView` 참조 +
  `applyFit`으로 동기화되는 `baseMagnification` 보유, `zoomIn`/`zoomOut`
  (min/max 클램프된 1.25×, 뷰포트 중심)과 `resetZoom` 노출하여 툴바
  버튼 + 메뉴 단축키(`⌘+`/`⌘-`/`⌘0`)와 `⌘ + 스크롤 휠`이 모두 같은
  코드 경로를 탐.
- **`SidebarMode`** — `pinned`와 `overlayVisible`을 가진 작은 순수 값 타입.
  `ReaderViewModel`이 인스턴스를 들고 있고 `pinned`만 유지. UI는
  `sidebarVisible`(computed)로 합성. 핫엣지 호버 노출은 `ReaderScene`의
  작은 `HotEdgeReveal` SwiftUI 뷰에 있고, 200 ms 지연 후
  `revealSidebarOverlay()` 발화; 오버레이에서 마우스 아웃 시 300 ms 후
  해제 예약. 툴바는 같은 고정 패턴(`toolbarPinned`)을 따르고 자동 숨김/
  고정 오버레이 로직을 공유.
- **`PositionKey.make(for:opened:tempRoot:)`** — `/tmp`로 추출된 소스의
  경우, 키가 연 URL과 임시 루트 내 상대 경로로부터 파생되어 재추출을
  가로질러 읽기 진행 유지. 페이지 북마크(`BookmarksStore`)도 같은 키를
  써서 temp-dir 재추출에도 유지됨.
- **`NSCache` 기반 이미지 캐시** — 페이지별 디코드된 `NSImage`를 메모리
  압박 시 자동 eviction. 프리로드는 페이지 모드에서 현재 페이지 ±2
  주변으로 취소 가능한 `Task` 실행. 취소는 `ImageLoader.load`와
  `preloadIfNeeded`로 전파되어 빠른 키보드 네비게이션 중 버려진 작업이
  캐시를 오염시키지 않음.
- **썸네일 캐시** — `ThumbnailLoader`가 `CGImageSourceCreateThumbnailAtIndex`로
  다운스케일된 NSImage 생성(풀 디코드 회피)하고 `NSCache`에 저장
  (`countLimit = 400`, `totalCostLimit ≈ 60 MB`). 썸네일 사이드바의
  `LazyVStack`이 보이는 셀만 머티리얼라이즈하고, 셀이 스크롤아웃되면
  `.task` 자동 취소로 in-flight 디코드를 자연 제한.
- **사이드바 2단계 로드** — `LibrarySidebar.reload`가 depth-1 스캔을 UI로
  즉시 전달한 뒤, 더 깊은 depth-3 스캔을 백그라운드에서 실행하고 준비
  완료 시 트리 교체. `FileNode.loadTree`는 최상위 서브트리 스캔을 청크
  `TaskGroup`으로 병렬화하여 큰 라이브러리가 1–2초 대신 ~100–200 ms에 열림.
- **설정 배치 읽기** — `ReaderViewModel.init`이
  `UserDefaults.standard.dictionaryRepresentation()`을 한 번 스냅샷하고
  메모리 dict에서 모든 키를 읽어, 콜드 스타트 때 수십 개의 개별
  cross-process `UserDefaults` 호출 회피.
- **디바운스된 위치 저장** — `currentPageIndex` didSet이 300 ms 디바운스된
  `savePosition`을 예약해서 세로 스크롤의 ~60 Hz 페이지 변경이
  `UserDefaults` 쓰기로 이어지지 않게 함. `NSApplication.willTerminateNotification`이
  종료 직전 `flushPositionImmediately`를 발화.
- **Security-scoped 북마크** — 최근 항목과 즐겨찾기가 실행 간 유지되는 이유는
  `.withSecurityScope` 북마크를 생성하고 클릭 시 resolve하기 때문. 스코프
  생명주기는 루트 URL에서 추적되므로 선택된 트리 내 형제 네비게이션이
  재프롬프트를 요구하지 않음.
- **창 닫기 → 앱 종료** — `PanelyAppDelegate`가
  `applicationShouldTerminateAfterLastWindowClosed`에서 true 반환하여
  단일창 뷰어의 빨간 닫기 버튼 동작이 종료와 일치.
- **방해 없는 크롬** — `.windowStyle(.hiddenTitleBar)`와
  `.preferredColorScheme(.dark)`가 전체 창을 뷰어 자체처럼 동작하게 함;
  신호등 버튼은 남아있되 타이틀 텍스트는 사라짐.

## 릴리스

릴리스는 `v*`와 일치하는 태그가 푸시될 때
[`.github/workflows/release.yml`](.github/workflows/release.yml)에 의해
자동 빌드 및 공개됩니다.

가장 쉬운 방법은 헬퍼 스크립트:

```bash
scripts/release.sh patch   # 1.0.0 → 1.0.1
scripts/release.sh minor   # 1.0.1 → 1.1.0
scripts/release.sh major   # 1.1.0 → 2.0.0
scripts/release.sh 1.2.3   # 명시적 버전
scripts/release.sh         # 인터랙티브 프롬프트
```

스크립트 동작:

1. 작업 트리가 깨끗하고, `main`에 있으며, origin과 동기화되어 있고,
   태그가 로컬·원격 모두에 비어있는지 확인.
2. 로컬 테스트 실행 (`SKIP_TESTS=1`로 건너뛸 수 있음).
3. `project.pbxproj`의 `MARKETING_VERSION` 범프.
4. 커밋(`chore: release vX.Y.Z`) 및 주석 태그 생성.
5. `main`과 태그 푸시 (`NO_PUSH=1`로 푸시 전 중단 가능).

릴리스 커밋과 태그 푸시는 각각 `ci.yml`(Debug 빌드 + 테스트)과
`release.yml`(Release 빌드 + zip + GitHub Release)을 트리거. 둘 다
의도된 것으로, 범프 커밋 CI가 릴리스 소스 트리가 Debug에서 깨끗이
빌드되는지 검증하고, `release.yml`이 출시할 아티팩트를 생성.

수동으로 하고 싶다면:

```bash
git tag v1.0.0
git push origin v1.0.0
```

### CI / 저장소

- **CI**는 모든 push/PR에서 실행(`**/*.md`와 `docs/**` 제외), ad-hoc
  서명으로 Debug 빌드, 168개 테스트 전부 실행, 아티팩트 업로드 없음 —
  저장소 풋프린트는 사실상 0.
- **릴리스**는 GitHub Releases에 `ditto`로 단일 zip(~5–10 MB)을 첨부하여
  리소스 포크 보존.
- **SPM 캐시**가 이후 실행을 빠르게 하고, `Package.resolved`나
  `project.pbxproj` 변경 시 무효화.

## 앱 아이콘 재생성

`docs/icon/panely-icon-stacked.svg`를 수정했다면 icns를 재생성:

```bash
scripts/generate-app-icon.sh
```

이 스크립트는 SVG를 필요한 모든 사이즈(16–1024)로 래스터화하고,
ImageMagick으로 sRGB 프로파일을 임베딩하며, `iconutil`로
`Panely/AppIcon.icns`를 생성합니다. Homebrew의 `librsvg`와 `imagemagick`
필요.

## 기여

기여를 환영합니다. 다음을 유념해 주세요:

- **디자인 원칙 존중** — 방해 없고 미니멀한 UI 우선. 영구 크롬을
  추가하는 변경에는 매우 좋은 이유가 있어야 합니다.
- **macOS 컨벤션** — 아이콘은 SF Symbols, 네이티브 메뉴, 키보드 우선.
- **샌드박스 호환** — 사용자가 허용하지 않은 경로 접근 금지.
- **테스트된 로직** — 비트리비얼한 순수 함수는 `PanelyTests/`에 테스트와
  함께 들어와야 합니다.

이슈나 PR은 [github.com/sejoung/Panely](https://github.com/sejoung/Panely)에 열어주세요.

## 라이선스

Apache License 2.0 — [LICENSE](LICENSE) 참조.
