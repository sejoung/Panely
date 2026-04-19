# 📘 Panely PRD (Product Requirements Document)

## 1. Overview

**Product Name:** Panely  
**Platform:** macOS (initial)  
**Type:** Comic & Image Viewer  

Panely is a minimal, fast comic and image viewer focused on delivering a smooth, distraction-free reading experience. The product prioritizes performance, simplicity, and native macOS feel.

---

## 2. Goals

### Primary Goals
- Provide a **fast and smooth reading experience**
- Support **common comic formats (Folder, CBZ)**
- Deliver a **minimal UI with maximum content focus**

### Non-Goals (MVP)
- Editing images
- Cloud sync
- Social or sharing features

---

## 3. Target Users

- Comic readers (manga, webtoon)
- Designers reviewing image sequences
- Users who prefer lightweight native tools

---

## 4. Core Features (MVP)

### 4.1 File Handling
- Open folder
- Open CBZ file
- Natural file sorting
- Filter non-image files

### 4.2 Reading Experience
- Next / Previous page navigation
- Fit to screen / Fit to width
- Zoom (trackpad, scroll)
- Remember last reading position

### 4.3 Input
- Keyboard shortcuts
  - ← → : navigation
  - Space : next page
  - Cmd + O : open

---

## 5. Extended Features (Post-MVP)

### 5.1 Reading Modes
- Single page
- Double page
- Vertical scroll (webtoon mode)
- Right-to-left reading support

### 5.2 Navigation
- Thumbnail sidebar
- Page slider
- Quick jump

### 5.3 Library
- Recent items
- Favorites
- Bookmarks

---

## 6. UX Requirements

- UI must not distract from content
- Viewer must always occupy maximum space
- Smooth scrolling and page transitions
- Minimal clicks to open and read content

---

## 7. Performance Requirements

- Instant page switching (<100ms perceived)
- Preload adjacent pages (±2 pages)
- Async image decoding
- Memory-efficient large image handling

---

## 8. Technical Requirements

### Stack
- Swift
- SwiftUI (App structure)
- AppKit (viewer core)
- Image I/O (image decoding)

### File Support
- JPG, PNG, WEBP (optional later)
- CBZ (ZIP)

---

## 9. Architecture (High-Level)

```
App Layer (SwiftUI)
 ├─ Reader Feature
 ├─ Library Feature
 └─ Settings

Core Layer
 ├─ File Manager
 ├─ Archive (CBZ)
 ├─ Image Loader
 └─ Cache Manager

UI Layer
 ├─ SwiftUI Views
 └─ AppKit Viewer
```

---

## 10. Success Metrics

- App launch time < 1s
- Page transition latency < 100ms
- No noticeable lag during reading
- High session duration (continuous reading)

---

## 11. Future Opportunities

- AI panel detection (panel-by-panel reading)
- Cross-platform support (Windows)
- Cloud sync (optional)

---

# 🎯 Summary

Panely aims to be a fast, minimal, and highly focused comic viewer that delivers the best possible reading experience on macOS.

