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

### 🌕 Light Theme (Optional)

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
┌──────────────────────────────┐
│ Toolbar (auto-hide)          │
├───────────────┬──────────────┤
│ Sidebar       │ Viewer       │
│ (thumbnails)  │ (image)      │
└───────────────┴──────────────┘
```

### 규칙
- Viewer 영역은 항상 최대
- Sidebar는 toggle 가능
- Toolbar는 hover 시 표시

---

## 6. Components

### 📦 Viewer Container
- 배경: `bg.primary`
- 중앙 정렬
- padding 최소화

### 📚 Thumbnail Sidebar
- 배경: `bg.secondary`
- width: 200~260px
- hover 시 강조

### 🔘 Buttons

| 상태 | 스타일 |
|------|------|
| Default | 투명 |
| Hover | `bg.tertiary` |
| Active | accent |

---

### 📊 Slider (페이지 이동)
- 얇은 라인 스타일
- thumb는 작게

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

| Action | Duration |
|------|------|
| 페이지 전환 | 150ms |
| UI 표시/숨김 | 120ms |

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
struct PanelyColors {
    static let bgPrimary = Color(hex: "#0F1115")
    static let bgSecondary = Color(hex: "#1C1F26")
    static let accent = Color(hex: "#0A84FF")
}
```

---

# 🎯 Summary

Panely는 UI를 최소화하고 이미지 중심의 읽기 경험을 제공하는 macOS용 만화 뷰어 디자인 시스템이다.

