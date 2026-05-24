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
  📖 <a href="docs/manual.ko.md">사용 설명서</a> · <a href="docs/manual.md">User Manual</a>
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
  툴바 세그먼트 컨트롤로 모드 직접 선택(사이클 라운드트립 없음);
  키보드는 `⌘⇧1` / `⌘⇧2` / `⌘⇧3`
- **좌→우** 또는 **우→좌** 읽기(만화 친화). 세로 모드에서는 RTL 무시
  (웹툰은 위→아래), 방향 토글 자동 비활성화
- **세 가지 맞춤 모드** — 툴바 세그먼트 픽커(한 번 탭으로 직접 선택)와
  `⌘1`/`⌘2`/`⌘3` 단축키:
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
- **시리즈 연속 읽기** — 한 권의 마지막 페이지에 닿고 다음 시블링이 있으면
  뷰어 하단에 다음 권 파일명 + "Next volume" 버튼이 뜬 카드(Up next)가
  표시됨. 대칭으로 페이지 0에서 backward를 명시적으로 누르면 상단에
  "Previous" 카드가 등장 — Vol N을 처음 페이지 0에서 열었을 땐 카드가
  안 뜨고 사용자가 더 뒤로 가려는 의도를 표현해야만 노출. 카드가 떠 있는
  동안 forward/backward 키 한 번이면 권을 이동
- **진행 오버레이** — 큰 소스를 처리하는 동안 단계별 메시지
  (Opening / Extracting / Loading / Building vertical strip), 전부 백그라운드 스레드

### 파일 지원
- **폴더**, **CBZ**, **ZIP** 열기
- **시리즈 루트 자동 감지** — 볼륨들이 들어있는 폴더를 고르면 첫 번째가 열림
- **중첩 아카이브 추출**(최대 3단계 재귀, 누적 추출 5 GB 안전 상한 —
  zip-bomb 보호)
- **영속 zip-in-zip 캐시** — 추출된 중첩 아카이브가 content-addressed
  키(SHA256 of 경로 + 크기 + mtime)로
  `~/Library/Caches/panely-extraction-cache/`에 보관됨. 10 GB LRU 예산
  안에서 관리되어 같은 아카이브를 다시 열 때 즉시 표시. 소스 파일 편집
  시 mtime이 바뀌어 키도 바뀌므로 자동 재추출. 캐시 용량 확인과 수동
  정리는 **File → Settings…**(또는 **Panely → Settings…**)와
  **File → Clear Extraction Cache** 에서 가능.
- **진단 리포트 내보내기** — **Settings → Diagnostics** 에서 앱 버전/build,
  macOS 버전, 최근 Panely 로그, redacted 열기/로드 이벤트, 캐시 용량,
  현재 설정, 마지막 reader 에러를 담은 zip을 생성해 버그 리포트에 첨부할 수 있음.
- 자연 파일명 정렬(`1, 2, 10` — `1, 10, 2` 아님) — `NaturalSort` 헬퍼로
  모든 로더/스캐너에서 일관 적용
- 비이미지 파일과 숨김 항목 필터링

### 네비게이션
- **키보드 우선** — `← → Space` 페이지, `⌘[ ⌘]` 볼륨,
  `⌘1 ⌘2 ⌘3` 맞춤 모드, `⌘+ ⌘- ⌘0` 줌, `⌃⌘S` 사이드바 고정,
  `⌃⌘T` 툴바 고정, `⌘L` 뷰 크기 잠금, `⌘O` 열기
- **라이브러리 사이드바 기본 고정** — fresh install에서는 폴더 트리가
  보이도록 고정되어 시작. `⌃⌘S`(또는 고정 버튼)로 고정을 풀면 자동
  숨김 모드가 되고, **왼쪽 가장자리**에 호버(200 ms) 시 오버레이로
  슬라이드 인(드롭 섀도, 페이지 시프트 없음). 마우스가 나가면 300 ms
  후 자동 해제, `ESC`는 즉시 해제
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
  책별 페이지 기억. 외장 디스크의 mount 경로가 바뀌어도 위치를 복구할 수
  있도록 volume + file resource identifier 기반 보조 키를 함께 저장
- **레이아웃 + 방향 + 맞춤 모드 + 사이드바 고정 + 툴바 고정 + 자동 맞춤
  잠금** 모두 유지(레거시 `panely.sidebarVisible` 키는 새 고정 플래그로
  자동 마이그레이션)
- **북마크/즐겨찾기 안전 장치** — 책당 페이지 북마크 상한(500개) + 총 책
  엔트리 상한(200개)으로 `UserDefaults` 4 MB 한계 도달로 인한 일괄
  손실 방지. `bookmarkDataIsStale` 감지 시 자동 재생성으로 파일을
  옮겨도 즐겨찾기/최근이 끊기지 않음
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

## 파인더 연동

Panely는 Finder에서 폴더 · `.cbz` · `.zip`을 바로 열 수 있도록 등록됩니다.

- **파일** (`.cbz`, `.zip`) — 우클릭 → **다음으로 열기 → Panely**
- **폴더** — macOS는 폴더에 "다음으로 열기"를 표시하지 않으므로
  폴더를 Panely.app(또는 Dock 아이콘)에 **드래그**, 혹은 메뉴바
  **파일 → 다음으로 열기 → Panely**

### 문제 해결

우클릭 메뉴에 Panely가 안 보이거나 옛 버전이 여러 개 보일 때:

```bash
# 1) 디스크에 등록된 모든 Panely.app 위치 확인
mdfind "kMDItemCFBundleIdentifier == 'io.github.sejoung.Panely'"

# 2) 안 쓰는 사본을 휴지통으로 보낸 뒤 휴지통도 비우기
#    (DerivedData/Debug 빌드는 그대로 둬도 됨 — 다음 빌드 때 자동 재등록)

# 3) LaunchServices DB 초기화 + Finder 재시작
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -kill -r -domain local -domain system -domain user
killall -KILL Finder
```

Release 빌드를 `/Applications`에 두는 게 가장 안정적입니다 —
DerivedData의 Debug 빌드는 LaunchServices가 보통 후순위로 노출합니다.
다운받은 zip을 더블클릭하면 Archive Utility 임시 폴더에 풀어둔 사본이
LaunchServices 캐시에 남을 수 있으니, 우클릭 → "다음으로 압축 해제"로
풀어 바로 `/Applications`에 옮기는 걸 권장합니다.

## 단축키와 제스처

| 입력 | 동작 |
|:------|:-------|
| `⌘O` | 폴더 / CBZ / ZIP 열기 |
| `←` / `→` | 이전 / 다음 페이지 (방향 반영. 매칭되는 권 카드가 떠 있으면 다음/이전 권으로 이동) |
| `Space` | 다음 페이지 (Up next 카드가 떠 있으면 다음 권으로 이동) |
| `⌘[` / `⌘]` | 이전 / 다음 볼륨 |
| `⌘G` | 페이지 번호로 이동… (모달 프롬프트) |
| `⌘D` | 페이지 북마크 추가 / 제거 |
| `⌘⇧D` | 현재 책 즐겨찾기 추가 / 제거 |
| `⌘⇧[` / `⌘⇧]` | 현재 책의 이전 / 다음 페이지 북마크로 이동 |
| `⌘⇧1` / `⌘⇧2` / `⌘⇧3` | 단일 페이지 / 두 페이지 / 세로 스크롤 레이아웃 |
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

**52 스위트에 걸친 331개 테스트**가 다음을 커버:

`SnapshotGalleryTests`는 기본 테스트에서 발견은 되지만
`scripts/generate-snapshots.sh`가 스냅샷 생성 flag를 만들 때만 활성화됩니다.
따라서 기본 `xcodebuild test` 경로는 매뉴얼 PNG를 렌더링하거나 복사하지 않습니다.

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
- **SidebarMode / 사이드바 선호값** — pinned / overlay 상태 전이를 다루는
  순수 값 타입(값 타입 기본은 unpinned, pin 멱등, pinned 중 overlay
  no-op, unpin 시 남아있는 overlay 정리)과 `ReaderPreferences`의 기본
  고정 및 영속성
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
- **`PageBookmarksStore`** — 토글 추가/제거, 키 격리, 페이지 인덱스로
  정렬, next/previous 네비게이션, ID로 제거, 주입된 `KeyValueStoring`
  영속성 왕복
- **`FavoritesStore`** — 실제 임시 파일에 대한 토글 추가/제거,
  security-scoped 북마크가 원래 URL로 resolve
- **`ReaderPreferences`** — 모든 영속 설정(레이아웃 / 방향 / 맞춤 /
  사이드바 고정 등)의 `KeyValueStoring` 왕복, 잘못된 raw 값은 기본값으로
  fallback, 레거시 `panely.sidebarVisible` 키가 새 고정 플래그로 자동
  마이그레이션
- **`ReaderPositionStore`** — 빈 store는 0 반환, 캐시 lazy hydration,
  300 ms 디바운스가 빠른 `savePosition` 호출들을 합쳐서 마지막 값만 기록,
  primary 키가 file-identity fallback보다 우선, 두 키 모두에 미러 기록
- **`ReaderLibraryScope`** — `contains()`가 at-or-below 경로는 허용하고
  sibling-prefix 충돌은 거부, acquire/release 라이프사이클(비-Powerbox
  URL에서 acquire가 실패해도 이전 URL은 해제됨)
- **`ReaderTempDirectory` / `ExtractionCacheStore`** — 실제 임시 디렉터리
  대상 session adopt/cleanup, contains() 경계 정확성, session candidate
  유일성, `cleanupStaleEntries()` mtime 게이트(stale 제거, fresh 유지,
  비-panely 항목 무시), 그리고 추출 캐시: 파일별 안정적 `cacheKey`
  (mtime 민감), `cachedEntry` 히트/미스 + 히트 시 mtime touch,
  `enforceBudget()` 10 GB 초과 시 LRU eviction, `cacheSizeBytes()` /
  `clearCache(excluding:)` 수동 정리, `cleanup()`이 session dir은 삭제하되
  cache dir은 보존
- **`ReaderImageLoader`** — reset / `prepareForVerticalRebuild` /
  `cancelPreload` 상태 전이, `estimatedBitmapCost`가 Retina 백킹에는 픽셀
  치수 사용 + 플레이스홀더에는 size fallback, `lazyConcurrencyLimit`이
  [2, 8]로 클램프
- **`AppKitScrollerCoordinator`** — bounds 옵저버가 연속 레이아웃에서는
  page index + range 콜백 fire하지만 페이지 모드에서는 no-op,
  programmatic scroll 중에는 page 콜백 억제(lazy load는 여전히 진행),
  같은 페이지 알림 dedupe, 두 옵저버 모두 재부착해도 콜백 중복 발생 없음
- **`FavoriteBook` / `PageBookmark` Codable** — 왕복 충실도 + `isDirectory`
  없는 레거시 `FavoriteBook` JSON의 forward-compat 디코드
- **`ReaderViewModel` 북마크 가드** — 소스 미로드 시 `toggle*`,
  `canGo*Bookmark`, `currentPositionKey`가 no-op / false / nil
- **`ThumbnailLoader`** — 접근 불가 URL은 nil, 실제 PNG는 non-nil, 동일
  `ComicPage.id`는 `===`로 캐시된 `NSImage` 반환, 서로 다른 페이지는 별개 캐시 엔트리
- **`ImageLoader.load`** — eager-decode 파이프라인(`CGImageSource` +
  `kCGImageSourceShouldCacheImmediately`), 비이미지/누락 파일에 throw,
  반환된 NSImage의 `cgImage(...)`가 추가 디코드 패스 없이 즉시 resolve
- **End-of-volume / previous-volume 카드** — 가시성 술어, 파일명 라벨,
  `advanceForward()` / `goBackward()` 디스패치, prev 카드의 비대칭 트리거
  (사용자 명시 의도가 있어야만 cue arm). 페이지 0의 첫 fresh open에선
  카드가 안 뜨는 것까지 대칭 보장 테스트 포함
- **위치 메모리 in-memory mirror** — 첫 restore에서 주입된 key-value
  store로부터 캐시 hydrate, 이후 save/read 모두 in-memory dict에 hit.
  여러 책이 올바르게 공존하고, 같은 VM 내 최신 write가 재읽기 없이 반영됨
- **`TitleBarPassthrough`** — 주입된 settings reader를 통한 시스템
  더블클릭 선호값 매핑(`zoom` / `minimize` / `none`)
- **`PanelyAppDelegate`** — `applicationShouldTerminateAfterLastWindowClosed`가
  true 반환해서 빨간 닫기 버튼이 앱 종료

테스트는 소스 트리를 그대로 반영합니다: `PanelyTests/Core/Comic/`,
`PanelyTests/Features/Library/`, `PanelyTests/Features/Settings/`, 그리고
`PanelyTests/Features/Reader/{Model, Viewer, Thumbnails, ViewModel,
ViewModel/Collaborators}`. 공유 픽스처(실제 PNG 생성기 포함)는
`PanelyTests/TestFixtures.swift`에 있고, persistence 테스트는
`PanelyTests/TestKeyValueStore.swift`를 씁니다.

`RecentItem.Codable`은 `isDirectory`용 `decodeIfPresent` 경로를 포함하여
오래된 저장 엔트리가 스키마 범프를 넘어 살아남습니다.

## 프로젝트 구조

각 폴더의 최상단에는 그 폴더 외부에서 참조하는 타입만 둡니다. 내부 구현
(extensions, sub-views, AppKit 브리지, collaborators)은 하위 폴더로
모아두어 어떤 디렉터리든 열면 공개 API가 한눈에 보입니다.

```
Panely/
├── PanelyApp.swift                     # @main, 윈도우 스타일, .commands { fileCommands + viewCommands + goCommands }
├── ContentView.swift
├── AppDependencies.swift               # 주입되는 앱 서비스(cache, bookmark, persistence, system settings)
├── AppIcon.icns                        # docs/icon/*.svg에서 생성
├── Commands/                           # PanelyApp에 대한 @CommandsBuilder extension
│   ├── PanelyApp+FileCommands.swift    # Open / Open Recent
│   ├── PanelyApp+ViewCommands.swift    # chrome / 레이아웃 / 맞춤 / 줌 / autofit
│   └── PanelyApp+GoCommands.swift      # 페이지 이동 / 북마크 / 즐겨찾기 / 볼륨
├── Core/
│   ├── Comic/                          # loader, ComicSource/Page, natural sort, 이미지 메타데이터
│   ├── Diagnostics/
│   │   ├── AppLog.swift                # OSLog + redacted 진단 이벤트
│   │   └── DiagnosticLogStore.swift    # rolling recent-log.txt 캐시 파일
│   └── Extensions/                     # 공유 Foundation helper
├── DesignSystem/
│   ├── Tokens/                         # Color / Spacing / Typography / Motion
│   └── Primitives/                     # 아이콘 버튼, 슬라이더
├── Features/
│   ├── Reader/
│   │   ├── ReaderScene.swift           # ZStack: SidebarHost + ViewerArea + ThumbnailSidebarHost (~100줄, 진입 뷰)
│   │   ├── Scene/                      # ReaderScene 하위 뷰 (파일당 struct 하나)
│   │   │   ├── HotEdgeReveal.swift
│   │   │   ├── SidebarHost.swift               # 뷰모델 액션과 연결된 LibrarySidebar
│   │   │   ├── ThumbnailSidebarHost.swift      # 뷰모델 액션과 연결된 ThumbnailSidebar
│   │   │   ├── ViewerArea.swift                # 뷰어 + 키 핸들러 + 오버레이
│   │   │   ├── ReaderToolbarOverlay.swift
│   │   │   ├── ReaderSliderOverlay.swift
│   │   │   └── VolumeCardOverlays.swift        # end-of- + previous-volume 카드
│   │   ├── Model/                      # 값 타입 및 순수 헬퍼
│   │   │   ├── PageLayout.swift        # single/double/vertical + 순환 + isContinuous
│   │   │   ├── ReadingDirection.swift  # LTR / RTL
│   │   │   ├── FitMode.swift           # 3가지 + 순환
│   │   │   ├── FitCalculator.swift     # 순수 배율 계산
│   │   │   ├── PositionKey.swift       # 책별 안정적 위치 키
│   │   │   └── SidebarMode.swift       # pinned / overlay 상태 값 타입
│   │   ├── ViewModel/                  # @Observable @MainActor 리더 상태
│   │   │   ├── ReaderViewModel.swift           # 세션 상태 + 합성 (~180줄)
│   │   │   ├── Extensions/                     # 관심사별 로직 분할
│   │   │   │   ├── ReaderViewModel+Navigation.swift   # 페이지 네비, Quick jump, chrome 토글
│   │   │   │   ├── ReaderViewModel+Source.swift       # 로드 파이프라인 + 폴더/아카이브 스캐너
│   │   │   │   ├── ReaderViewModel+Volumes.swift      # 형제 권 카운터 + 볼륨 카드
│   │   │   │   ├── ReaderViewModel+ImageLoading.swift # ReaderImageLoader 위 얇은 facade
│   │   │   │   └── ReaderViewModel+Bookmarks.swift    # 즐겨찾기 + 페이지 북마크 연동
│   │   │   └── Collaborators/                  # ReaderViewModel이 합성, 각각 단일 책임
│   │   │       ├── ReaderPreferences.swift     # KeyValueStoring 기반 레이아웃 / 맞춤 / 고정
│   │   │       ├── ReaderPositionStore.swift   # 디바운스된 책별 페이지 메모리
│   │   │       ├── ReaderImageLoader.swift     # 캐시 + 페이지 새로고침 + 세로 지연 윈도 + 프리로드
│   │   │       ├── ReaderImageLoadingSupport.swift # 이미지 메모리 캐시 + 로딩 헬퍼
│   │   │       ├── ReaderTempDirectory.swift   # zip-in-zip session 추출 라이프사이클
│   │   │       ├── ExtractionCacheStore.swift  # content-addressed 추출 캐시 (10 GB LRU)
│   │   │       └── ReaderLibraryScope.swift    # security-scope grant 보유
│   │   ├── Viewer/                     # AppKit 기반 스크롤 가능 이미지 스테이지
│   │   │   ├── ViewerContainer.swift           # SwiftUI 셸 (스크롤러 진입점)
│   │   │   ├── ViewerController.swift          # 줌 리모트 (⌘+/-/0, 스크롤 휠)
│   │   │   └── AppKit/                         # 내부 AppKit 브리지
│   │   │       ├── AppKitImageScroller.swift       # NSViewRepresentable + applyFit
│   │   │       ├── AppKitScrollerCoordinator.swift # 옵저버 + 상태 diff
│   │   │       ├── PanelyScrollView.swift          # ⌘+휠 줌이 가능한 NSScrollView
│   │   │       ├── TitleBarPassthrough.swift       # 상단 28 px 드래그 + 커서 처리
│   │   │       ├── CenteringClipView.swift         # 작은 문서 중앙정렬 NSClipView
│   │   │       └── ImageStackView.swift            # 페이지 프레임 + 풀링된 NSImageView
│   │   ├── Toolbar/
│   │   │   ├── PanelyToolbar.swift     # 5개 버튼 그룹: chrome / 레이아웃 / 맞춤·줌 / 북마크 / 네비
│   │   │   └── QuickJumpField.swift    # 페이지 카운터 인라인 편집
│   │   ├── Overlays/
│   │   │   ├── LoadingOverlay.swift
│   │   │   ├── VolumeCardChrome.swift  # 공유 머티리얼/섀도우/보더 ViewModifier
│   │   │   ├── EndOfVolumeCard.swift   # 하단 카드: "Up next" + start/restart
│   │   │   └── PreviousVolumeCard.swift # 상단 카드: "Previous" (의도 게이트)
│   │   └── Thumbnails/
│   │       ├── ThumbnailSidebar.swift  # 우측 썸네일 패널 (LazyVStack)
│   │       └── ThumbnailLoader.swift   # Image I/O 썸네일 + NSCache
│   ├── Settings/
│   │   ├── SettingsView.swift          # Storage + Diagnostics 탭
│   │   ├── StorageSettingsView.swift   # Storage 설정 UI + 캐시 용량 / 삭제 컨트롤
│   │   ├── DiagnosticsSettingsView.swift # 진단 리포트 export UI
│   │   ├── DiagnosticReportExporter.swift # zip 리포트 writer
│   │   └── CacheMaintenance.swift      # 캐시 삭제 결과와 포맷팅 헬퍼
│   └── Library/
│       ├── LibrarySidebar.swift        # 고정 버튼 + 확장자 배지 + 2단계 로드
│       ├── LibrarySidebarModel.swift   # 사이드바 표시 모델
│       ├── LibraryTreeLoader.swift     # 주입 가능한 FileNode.loadTree 래퍼
│       ├── Model/
│       │   ├── FileNode.swift          # iconName + fileExtension + 최상위 병렬 스캔
│       │   ├── RecentItem.swift        # security-scoped 최근 항목
│       │   ├── FavoriteBook.swift      # 영속 즐겨찾기 (security-scoped bookmark)
│       │   └── PageBookmark.swift      # 영속 페이지 북마크
│       ├── Store/
│       │   ├── FavoritesStore.swift            # 즐겨찾은 책 (security-scoped, stale 자동 갱신)
│       │   ├── PageBookmarksStore.swift        # 책당 + 총 책 상한이 적용된 페이지 북마크
│       │   └── RecentItemsStore.swift          # 재열기 시 북마크 중복 제거
│       └── Rows/                       # 사이드바 row 뷰 (파일당 struct 하나)
│           ├── FileNodeRow.swift
│           ├── FavoriteRow.swift
│           ├── VolumeRow.swift
│           └── PageBookmarkRow.swift
└── Core/
    ├── Extensions/                     # 공유 Foundation 유틸 extension (DRY)
    │   ├── URL+IsAncestor.swift        # path-component 단위 접두사 포함 체크
    │   └── UserDefaults+Codable.swift  # KeyValueStoring + JSON encode/decode 헬퍼
    └── Comic/
        ├── ComicPage.swift / ComicSource.swift / ComicPageSource.swift
        ├── FolderLoader.swift
        ├── CBZLoader.swift             # 평면 + 재귀 중첩 추출 + 5 GB 안전 상한
        ├── ArchiveReader.swift         # ZIPFoundation.Archive 감싼 actor
        │                               # (헤더 전용 읽기용 loadDataPrefix)
        ├── NaturalSort.swift           # 로케일 인식 자연 정렬 헬퍼
        └── ImageLoader.swift           # async NSImage + dimensions(for:) 헤더 읽기

PanelyTests/                            # 소스 트리를 미러링
├── TestFixtures.swift                  # 공유 temp-dir / zip / PNG 헬퍼
├── PanelyAppDelegateTests.swift
├── FileAssociationTests.swift
├── TestKeyValueStore.swift             # persistence 테스트용 in-memory KeyValueStoring
├── Snapshots/                          # docs/screenshots/ 생성기 (CI에서 skip)
│   ├── SnapshotRenderer.swift          # NSHostingView + offscreen window → PNG
│   ├── SnapshotSampleContent.swift     # placeholder 페이지 + LibraryFixture
│   └── SnapshotGalleryTests.swift      # 13개 매뉴얼 시나리오
├── Core/Comic/                         # CBZLoader, FolderLoader, ImageLoader{Load,Dimensions},
│                                       # ComicModel, LoaderExtension, NaturalSort
├── Features/Library/                   # FavoritesStore, PageBookmarksStore, RecentItem,
│                                       # FileNode, FavoriteBook, PageBookmark
├── Features/Settings/                  # CacheMaintenance, Settings UI, diagnostic report export
└── Features/Reader/
    ├── Model/                          # FitCalculator, PositionKey, ReaderEnum, SidebarMode
    ├── Viewer/                         # CenteringClipView, FitMagnificationStability,
    │                                   # ImageStackVertical, ScrollZoomCalculator,
    │                                   # ViewerController, ViewerResizeFit,
    │                                   # AppKitScrollerCoordinator, TitleBarPassthrough
    ├── Thumbnails/                     # ThumbnailLoader
    └── ViewModel/                      # 통합 테스트 10개 (Bookmarks, EndOfVolume,
        │                               # Library, PagedMode, PositionMemory, QuickJump,
        │                               # SetLayout, ThumbnailSidebar, ToolbarPin,
        │                               # VerticalMode)
        └── Collaborators/              # collaborator들의 포커싱된 단위 테스트

docs/
├── manual.md                           # 영문 사용 설명서 (스크린샷 둘러보기)
├── manual.ko.md                        # 한글 사용 설명서
├── screenshots/                        # SnapshotGalleryTests가 생성하는 13개 PNG
├── panely_design_system_mac_os.md
└── icon/panely-icon-stacked.svg

scripts/
├── generate-app-icon.sh                # SVG → .icns 파이프라인
├── generate-snapshots.sh               # SnapshotGalleryTests로 docs/screenshots/*.png 재생성
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
  보냅니다. 클래스 본체는 세션 상태와 포커싱된 **collaborator**
  (`ReaderPreferences`, `ReaderPositionStore`, `ReaderImageLoader`,
  `ReaderTempDirectory`, `ReaderLibraryScope`)와 공유 서비스용
  `AppDependencies`(추출 캐시, security-scoped bookmark, 라이브러리 트리
  로딩, key-value persistence, 시스템 설정)를 보유합니다. 각 observable
  프로퍼티를 forwarding으로 노출해서 뷰 호출(`viewModel.layout`,
  `viewModel.currentImages`)이 그대로 동작하면서도 내부 타입들은 독립적으로
  상태를 소유합니다. 관심사별 로직은 다섯 extension(`+Navigation`,
  `+Source`, `+Volumes`, `+ImageLoading`, `+Bookmarks`)에 분할됩니다.
- **Dependency-injected 앱 서비스** — production은 `AppDependencies.live`를
  쓰고, 테스트는 protocol 기반 서비스(`ExtractionCacheManaging`,
  `SecurityScopedBookmarking`, `LibraryTreeLoading`, `KeyValueStoring`,
  `SystemSettingsReading`)를 주입해 실제 앱 preference, cache root,
  sandbox bookmark를 건드리지 않음.
- **`nonisolated` 코어 타입** — `ComicPage`, `FolderLoader`, `CBZLoader`,
  `ImageLoader`, `FitCalculator`, `PositionKey`는 `Task.detached`로
  메인 스레드 밖에서 실행.
- **`actor ArchiveReader`** — ZIPFoundation의 `Archive`를 감싸 순차적,
  스레드 안전한 엔트리 읽기 제공.
- **AppKit 뷰어 코어** — `ViewerContainer`는 SwiftUI지만 스크롤 가능한 줌
  스테이지는 `AppKitImageScroller`(`NSViewRepresentable`)가 `NSScrollView`
  + `CenteringClipView` + 커스텀 `ImageStackView`를 감쌈.
  `acceptsFirstResponder`를 꺼두어 키보드 이벤트가 SwiftUI의
  `.onKeyPress`로 흘러감. `AppKitScrollerCoordinator`가 브리지의 AppKit
  쪽 상태(직전에 본 SwiftUI props — 변화 감지용, 두 NotificationCenter
  옵저버 토큰, `applyFit` 호출)를 모두 소유하여 representable 자체는
  SwiftUI ↔ AppKit 핸드셰이크에만 집중.
- **`CenteringClipView`**는 `constrainBoundsRect(_:)`를 오버라이드하여
  뷰포트가 더 클 때 문서를 중앙에 둠 — 사이드바 토글 시 이미지 중심 유지.
- **`TitleBarPassthrough`** — 뷰어 상단 28 px에 얹는 얇은 NSView.
  `mouseDownCanMoveWindow = true`로 네이티브 창 드래그,
  `NSTrackingArea`를 신호등 영역 외부에만 걸어 open-hand 커서가
  close/minimize/zoom 버튼 위에 새지 않도록 함, `mouseDown` 오버라이드에서
  주입된 `SystemSettingsReading`을 통해 더블클릭 zoom/minimize/none 처리
  (production에서는 `AppleActionOnDoubleClick`). `.hiddenTitleBar` 아래에서
  실제 창 가장자리와 정렬되도록 `.ignoresSafeArea(edges: .top)` 사용.
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
  `ReaderPreferences`가 인스턴스를 들고 `pinned`만 영속화하며,
  `ReaderViewModel`이 `sidebarPinned` / `sidebarOverlayVisible` /
  `sidebarVisible`(computed)을 forwarding하므로 뷰 호출은 그대로. 핫엣지
  호버 노출은 `ReaderScene`의 작은 `HotEdgeReveal` SwiftUI 뷰에 있고,
  200 ms 지연 후 `revealSidebarOverlay()` 발화; 오버레이에서 마우스 아웃
  시 300 ms 후 해제 예약. 툴바는 같은 고정 패턴(`toolbarPinned`)을
  따르고 자동 숨김/고정 오버레이 로직을 공유.
- **`PositionKey.make(for:opened:tempRoot:)`** — `/tmp`로 추출된 소스의
  경우, 키가 연 URL과 임시 루트 내 상대 경로로부터 파생되어 재추출을
  가로질러 읽기 진행 유지. 페이지 북마크(`PageBookmarksStore`)도 같은
  키를 써서 temp-dir 재추출에도 유지됨. 추가로 `PositionKey.fileIdentity(for:)`로
  `(volumeIdentifier, fileResourceIdentifier)` 기반 보조 키를 생성해
  외장 디스크 mount 경로가 변경돼도 위치 복구. 저장 시 두 키 모두에
  현재 인덱스를 기록하고, 조회 시 path 키 → fileIdentity 키 순서로
  fallback.
- **결정적 `ComicPage.id`** — 페이지 식별자는 source에서 파생된 결정적
  문자열(`file:<path>` 또는 `archive:<archiveURL>#<entryPath>`). 책을
  다시 열어도 같은 `id`가 나오므로 이미지/썸네일 `NSCache`가 그대로
  히트 — 기존 무작위 UUID 방식은 reopen마다 전량 재디코드 발생.
- **`NSCache` 기반 이미지 캐시** — 페이지별 디코드된 `NSImage`를 메모리
  압박 시 자동 eviction. `countLimit = 100`로 vertical lazy window의
  `±lazyKeepBuffer` 페이지가 cost 여유에도 LRU eviction 당하는 문제를
  해소. 실제 예산은 `totalCostLimit ≈ 150 MB`이며, bitmap rep의
  `pixelsWide × pixelsHigh × (bitsPerSample × samplesPerPixel / 8)`로
  per-entry cost를 계산해 Retina backing 이나 16-bit/HDR 스캔이
  과소평가되지 않음. 프리로드는 페이지 모드에서 현재 페이지 ±2 주변으로
  취소 가능한 `Task` 실행. 취소는 `ImageLoader.load`와 `preloadIfNeeded`로
  전파되어 빠른 키보드 네비게이션 중 버려진 작업이 캐시를 오염시키지 않음.
- **북마크/즐겨찾기 영속성 안전 장치** — `PageBookmarksStore`의 페이지
  북마크는 `maxBookmarksPerBook = 500`(초과 시 오래된 항목부터 drop),
  전체 책 엔트리는 `maxBookEntries = 200`(초과 시 가장 오래 손대지 않은
  책의 엔트리 drop). `pruneOrphaned(keeping:)`로 라이브 키 집합 바깥의
  고아 엔트리를 일괄 GC 가능. `RecentItemsStore.resolve` /
  `FavoritesStore.resolve`는 `bookmarkDataIsStale` 감지 시 즉시 새
  bookmark를 만들어 store에 갱신해 외장 디스크 이름 변경/파일 이동을
  실패 없이 흡수. `RecentItemsStore.record`의 빠른 reopen 경로도 같은
  stale 체크를 수행. 세 store 모두 `Core/Extensions/`의
  `KeyValueStoring.loadCodable(_:forKey:)` / `saveCodable(_:forKey:)`를
  공유해 JSON 인/디코드 보일러플레이트를 한 곳에 둠
  (`LiveKeyValueStore`는 `UserDefaults` 기반).
- **CBZ 추출 안전 상한** — `CBZLoader.maxExtractedBytes = 5 GB`. `extractAll`
  완료 후(그리고 각 중첩 추출 후) 디렉터리 트리를 한 번 walk하여
  누적 크기가 상한을 넘으면 `LoadError.extractedSizeExceeded`를 throw
  하고 부분 추출물을 정리 — zip-bomb / 비정상 중첩 아카이브로부터
  디스크 보호.
- **앱 시작 시 임시 디렉터리 청소** — `ReaderTempDirectory.cleanupStaleEntries`는
  mtime이 10분 이상 지난 session `panely-<uuid>` 디렉터리만 정리. 첫 실행
  중 진행 중인 추출 디렉터리가 동시에 삭제되는 경쟁 방지.
  `~/Library/Caches/panely-extraction-cache/` 아래의 캐시 디렉터리는
  주입된 extraction cache manager가 관리하며, 같은 startup 훅이
  `enforceBudget()`을 호출.
- **Content-addressed 추출 캐시** — `ExtractionCacheStore`의 `cacheKey(for:)`가
  소스 아카이브의 경로 + 크기 + mtime을 SHA256으로 해시(64 bit로 truncate).
  `cachedEntry(forKey:)`는
  캐시 디렉터리가 존재하고 비어있지 않을 때만 반환(비어있지 않은지 체크는
  부분 추출이 serve되는 것을 방지)하며, 히트 시 디렉터리 mtime을
  touch해서 LRU 정책에서 가장 최근으로 마크. 새 추출은
  `makeCachedCandidate(forKey:)`로 가고, 소스가 stat 불가일 때만 UUID
  기반 session dir로 fallback. `enforceBudget()`은 새 캐시 entry adopt 후
  백그라운드에서 + 앱 시작 시 실행.
- **마지막 spread 도달 가능한 위치 복원** — `clampedRestoredIndex`가
  `pageCount - 1`이 아니라 step 정렬된 마지막 인덱스
  (`((pageCount - 1) / step) * step`)로 클램프. 더블 페이지 모드에서
  마지막 spread로 종료한 책을 다시 열면 한 spread 뒤가 아니라 정확히
  그 spread로 복원.
- **AppKit 옵저버 방어** — `AppKitScrollerCoordinator.attachFrameObserver(to:)`
  / `attachBoundsObserver(to:)`가 등록 전 기존 토큰을 명시 제거하므로,
  SwiftUI가 representable을 재생성해도 coordinator에 auto-fit / 스크롤
  핸들러가 중복 누적되지 않음. 두 토큰 모두 coordinator의 `deinit`에서
  해제됨. `AppKitScrollerCoordinatorTests`(재부착 시 중복 발사 없음,
  deinit 누수 없음)로 보장.
- **Eager-decode 이미지 파이프라인** — `ImageLoader.load`는
  `CGImageSourceCreateWithURL`(파일 URL은 zero-copy mmap) /
  `CGImageSourceCreateWithData`(아카이브 엔트리)를 `Task.detached` 안에서
  돌리고, `kCGImageSourceShouldCacheImmediately: true`로 반환되는
  NSImage가 완전히 realize된 CGImage를 백킹하도록 함. `NSImage(data:)`가
  첫 그리기까지 미루는 lazy decode를 회피.
- **페이지 모드 새로고침 병렬화** — `refreshPaged`가 보이는 spread
  (double-page 모드의 2페이지)를 `withTaskGroup`으로 동시 디코드하고
  원래 순서로 `currentImages`를 한 번에 커밋. single 레이아웃은 영향
  없음, double 레이아웃은 ~2배 빠름.
- **시리즈 연속 읽기** — `ReaderViewModel.showsEndOfVolumeCard`는 순수
  술어 `isAtLastPage && canGoNextVolume`. 대칭 prev 카드
  (`showsPreviousVolumeCard`)는 transient cue
  `wantsPreviousVolumePrompt`로 게이트되어 사용자 명시 의도(페이지 0에서
  backward 누름, 또는 더 위에서 `goBackward()`로 0에 도달)가 있을 때만
  arm. 이후 `currentPageIndex` 변경은 cue를 클리어하고, `load(url:)`은
  새 책 로드 시 cue를 리셋해 새 권 첫 페이지에서 카드가 미리 뜨지
  않도록 함. forward/backward 키보드 핸들러는 `advanceForward()` /
  `goBackward()`로 라우팅되어, 매칭되는 카드가 떠 있을 때 한 번 누르면
  권 이동.
- **썸네일 캐시** — `ThumbnailLoader`가 `CGImageSourceCreateThumbnailAtIndex`로
  다운스케일된 NSImage 생성(풀 디코드 회피)하고 `NSCache`에 저장
  (`countLimit = 400`, `totalCostLimit ≈ 60 MB`). 썸네일 사이드바의
  `LazyVStack`이 보이는 셀만 머티리얼라이즈하고, 셀이 스크롤아웃되면
  `.task` 자동 취소로 in-flight 디코드를 자연 제한.
- **사이드바 2단계 로드** — `LibrarySidebar.reload`가 depth-1 스캔을 UI로
  즉시 전달한 뒤, 더 깊은 depth-3 스캔을 백그라운드에서 실행하고 준비
  완료 시 트리 교체. `FileNode.loadTree`는 최상위 서브트리 스캔을 청크
  `TaskGroup`으로 병렬화하여 큰 라이브러리가 1–2초 대신 ~100–200 ms에 열림.
- **설정 배치 읽기** — `ReaderPreferences.init`이 주입된
  `KeyValueStoring.dictionaryRepresentation()`을 한 번 스냅샷하고 메모리
  dict에서 모든 키를 읽어, live store 기준 콜드 스타트 때 수십 개의
  개별 cross-process `UserDefaults` 호출 회피.
- **디바운스된 위치 저장 + in-memory mirror** — `currentPageIndex`
  didSet이 `ReaderPositionStore.savePosition(...)`으로 라우팅되어 300 ms
  디바운스된 쓰기를 예약하므로 세로 스크롤의 ~60 Hz 페이지 변경이
  `UserDefaults` 쓰기로 이어지지 않음. save와 read는 lazy in-memory
  mirror를 거쳐서 매 save가 저장된 모든 책의 dict를 read-modify-write하지
  않고 작은 dict 변경 + 단일 `set(_:forKey:)`로 끝남.
  `NSApplication.willTerminateNotification`이 종료 직전 pending write를
  flush.
- **Security-scoped 북마크** — 최근 항목과 즐겨찾기가 실행 간 유지되는 이유는
  `.withSecurityScope` 북마크를 생성하고 클릭 시 resolve하기 때문. 활성
  라이브러리 루트 grant는 `ReaderLibraryScope`가 보유(한 번에 하나의 URL,
  `acquire`/`release` 쌍)하므로 선택된 트리 내 형제 네비게이션이
  재프롬프트를 요구하지 않고, 새 grant 획득 전에 이전 grant가 항상
  release됨.
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
  서명으로 Debug 빌드, 스냅샷 제외 테스트 suite 실행, 아티팩트 업로드
  없음 — 저장소 풋프린트는 사실상 0. `SnapshotGalleryTests`는 어설션이
  없는 매뉴얼 스크린샷 생성기라서 기본으로 gate off; 매뉴얼 PNG가 필요하면
  `scripts/generate-snapshots.sh`로 수동 재생성.
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
