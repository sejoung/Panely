# 🎨 Panely Design System (macOS)

## 1. Design Principles

### 🧭 Core Values
- **Distraction-Free**: 콘텐츠(이미지)에 집중
- **Minimal UI**: UI는 최대한 숨겨짐
- **Native Feel**: macOS처럼 자연스럽게 동작
- **Smooth Reading**: 끊김 없는 흐름

---

## 2. Color System

### 🌑 Primary Theme (Dark First)
> 만화 뷰어는 다크모드 기본

| Token | Value | Usage |
|------|------|------|
| `bg.primary` | `#0F1115` | 전체 배경 |
| `bg.secondary` | `#1C1F26` | 패널/사이드바 |
| `bg.tertiary` | `#2A2E36` | hover / 구분 |
| `text.primary` | `#E6EAF2` | 기본 텍스트 |
| `text.secondary` | `#AAB2C0` | 보조 텍스트 |
| `border.subtle` | `rgba(255,255,255,0.08)` | 구분선 |
| `accent.primary` | `#0A84FF` | 강조 |

---

### 🌕 Light Theme (미구현)

> 현재 앱은 다크 전용입니다 (`.preferredColorScheme(.dark)`). 아래 값은 코드에
> 토큰으로 존재하지 않는 참고용 제안입니다.

| Token | Value |
|------|------|
| `bg.primary` | `#FFFFFF` |
| `bg.secondary` | `#F5F7FA` |
| `text.primary` | `#1C1F26` |

---

### 🎯 Color Usage Rules
- 배경은 항상 저채도 유지
- 이미지보다 눈에 띄지 않게
- accent는 최소 사용

---

## 3. Typography

### 기본
- Font: San Francisco (System Default)

### Scale

| Style | Size | Weight |
|------|------|------|
| Title | 20 | Semibold |
| Body | 14 | Regular |
| Caption | 12 | Regular |

---

## 4. Spacing System

기본 단위: 4pt grid

| Token | Value |
|------|------|
| `space.xs` | 4 |
| `space.sm` | 8 |
| `space.md` | 12 |
| `space.lg` | 16 |
| `space.xl` | 24 |

---

## 5. Layout

### 구조

```
┌──────────┬────────────────────────────┬───────────┐
│ Library  │ Toolbar (floating, hide)   │ Thumbnail │
│ Sidebar  │                            │ Sidebar   │
│ (240pt)  │ Viewer (image)             │ (148pt)   │
│          │                            │           │
│          │ Page slider (auto-hide)    │           │
└──────────┴────────────────────────────┴───────────┘
```

### 규칙
- Viewer 영역은 항상 최대
- Library sidebar(왼쪽)는 고정하거나 왼쪽 가장자리 hover 시 오버레이로 표시
- Thumbnail sidebar(오른쪽)는 toggle 가능 (`⌃⌘P`)
- Toolbar와 페이지 슬라이더는 뷰어 위/아래 가장자리(80pt) hover 시 표시

---

## 6. Components

### 📦 Viewer Container
- 배경: `bg.primary`
- 중앙 정렬
- padding 최소화

### 📚 Library Sidebar
- 배경: `bg.secondary`
- width: 240pt
- 섹션 헤더: `caption`, `text.secondary`

### 🖼 Thumbnail Sidebar
- 배경: `bg.secondary`
- width: 148pt (썸네일 셀 폭 112pt, placeholder `bg.tertiary`, radius 4)
- 현재 페이지: `accent.primary` 2pt 외곽선 + 페이지 번호 accent

### 🔘 Buttons

| 상태 | 스타일 |
|------|------|
| Default | 투명 |
| Hover | `bg.tertiary` |
| Active | accent 배경 + 흰색 아이콘 |

- 크기 32×32pt, corner radius 6 (continuous)
- 아이콘: SF Symbols 14pt medium, 기본 색 `text.primary`
- 상태 변화 애니메이션: `uiReveal`

---

### 📊 Slider (페이지 이동)
- 얇은 라인 스타일: track 2pt (`bg.tertiary`), 진행 구간 `accent.primary`
- thumb는 작게: 10pt 원 (`text.primary`)
- 터치 영역 높이 20pt, 드래그 종료 시 페이지 단위로 스냅

---

## 7. Interaction

### 🖱 기본 인터랙션
- Hover → subtle background
- Click → 빠른 반응
- Scroll → 자연스러운 inertia

### ⌨️ 키보드
- ← → : 페이지 이동
- Space : 다음
- Cmd + O : 열기

---

## 8. Motion

### 원칙
- 빠르고 짧게
- 과하지 않게

| Token | Action | Duration |
|------|------|------|
| `pageTransition` | 페이지 전환 | 150ms (easeOut) |
| `uiReveal` | UI 표시/숨김 | 120ms (easeOut) |

---

## 9. Icon Style

- Stroke 기반
- 1.5~2px 두께
- 라운드 코너

---

## 10. Accessibility

- 충분한 대비 확보
- 키보드 네비게이션 지원
- 안정적인 줌

---

## 11. SwiftUI Token Example

```swift
enum PanelyColor {
    static let bgPrimary = Color(hex: 0x0F1115)
    static let bgSecondary = Color(hex: 0x1C1F26)
    static let accentPrimary = Color(hex: 0x0A84FF)
}
```

---

# 🎯 Summary

Panely는 UI를 최소화하고 이미지 중심의 읽기 경험을 제공하는 macOS용 만화 뷰어 디자인 시스템이다.

