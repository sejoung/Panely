import AppKit
import Testing
@testable import Panely

@MainActor
struct AppMenuLocalizationTests {
    @Test func standardMenusSwitchInBothDirectionsWithoutReplacingCommands() {
        let localization = AppLocalization(language: "en")
        let menu = NSMenu()
        let app = addMenu("Panely", to: menu)
        let target = NSObject()
        let quit = app.addItem(withTitle: "Quit Panely", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = target
        quit.keyEquivalentModifierMask = [.command]
        quit.isEnabled = false
        let file = addMenu("File", to: menu)
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = addMenu("Edit", to: menu)
        let copy = edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let view = addMenu("View", to: menu)
        let fullScreen = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        let window = addMenu("Window", to: menu)
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let resize = addMenu("Move & Resize", to: window)
        let fill = resize.addItem(withTitle: "Fill", action: nil, keyEquivalent: "")
        let fullScreenMenu = addMenu("Full Screen", to: window)
        let entireScreen = fullScreenMenu.addItem(withTitle: "Entire Screen", action: nil, keyEquivalent: "")
        addMenu("Help", to: menu)
        let localizer = AppMenuLocalizer(localization: localization, mainMenu: { menu })

        localization.apply(.korean)
        localizer.apply()

        #expect(menu.items.map(\.title) == ["Panely", "파일", "편집", "보기", "윈도우", "도움말"])
        #expect(menu.items.map { $0.submenu!.title } == menu.items.map(\.title))
        #expect(quit.title == "Panely 종료")
        #expect(copy.title == "복사")
        #expect(fullScreen.title == "전체 화면 시작")
        #expect(window.items.first?.title == "최소화")
        #expect(window.items[1].title == "이동 및 크기 조절")
        #expect(fill.title == "채우기")
        #expect(fullScreenMenu.title == "전체 화면")
        #expect(entireScreen.title == "전체 화면")
        #expect(quit === app.items.first)
        #expect(quit.action == #selector(NSApplication.terminate(_:)))
        #expect(quit.target === target)
        #expect(quit.keyEquivalent == "q")
        #expect(quit.keyEquivalentModifierMask == [.command])
        #expect(!quit.isEnabled)

        fullScreen.title = "Exit Full Screen"
        localizer.apply()
        #expect(fullScreen.title == "전체 화면 종료")

        localization.apply(.english)
        localizer.apply()
        #expect(menu.items.map(\.title) == ["Panely", "File", "Edit", "View", "Window", "Help"])
        #expect(quit.title == "Quit Panely")
        #expect(copy.title == "Copy")
        #expect(fullScreen.title == "Exit Full Screen")
        #expect(window.items[1].title == "Move & Resize")
        #expect(fill.title == "Fill")
        #expect(fullScreenMenu.title == "Full Screen")
        #expect(entireScreen.title == "Entire Screen")
    }

    @Test func customMenusDocumentNamesAndServicesKeepTheirTitles() {
        let localization = AppLocalization(language: "ko")
        let menu = NSMenu()
        let file = addMenu("File", to: menu)
        let recent = addMenu("Open Recent", to: file)
        let book = recent.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")
        let go = addMenu("Go", to: menu)
        let custom = go.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")
        let app = addMenu("Panely", to: menu)
        let services = addMenu("Services", to: app)
        let service = services.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")
        let window = addMenu("Window", to: menu)
        let document = window.addItem(withTitle: "Copy", action: #selector(NSWindow.makeKeyAndOrderFront(_:)), keyEquivalent: "")
        let edit = addMenu("Edit", to: menu)
        let undo = edit.addItem(withTitle: "Undo Typing", action: NSSelectorFromString("undo:"), keyEquivalent: "z")

        AppMenuLocalizer(localization: localization, mainMenu: { menu }).apply()

        #expect(book.title == "Copy")
        #expect(custom.title == "Copy")
        #expect(service.title == "Copy")
        #expect(document.title == "Copy")
        #expect(undo.title == "Undo Typing")
        #expect(app.items.first?.title == "서비스")
    }

    @Test func languageChangesAndRebuiltMenusAreAppliedAutomatically() async {
        let localization = AppLocalization(language: "en")
        let menu = NSMenu()
        let edit = addMenu("Edit", to: menu)
        let copy = edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let localizer = AppMenuLocalizer(localization: localization, mainMenu: { menu })
        localizer.start()
        defer { localizer.stop() }

        localization.apply(.korean)
        await settleMenuUpdates()
        #expect(menu.items.first?.title == "편집")
        #expect(copy.title == "복사")

        copy.title = "Copy"
        let paste = edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        await settleMenuUpdates()
        #expect(copy.title == "복사")
        #expect(paste.title == "붙여넣기")

        localization.apply(.english)
        await settleMenuUpdates()
        #expect(menu.items.first?.title == "Edit")
        #expect(copy.title == "Copy")
        #expect(paste.title == "Paste")
    }

    @Test func menuCreatedAfterLaunchUsesTheSelectedLanguage() async {
        let localization = AppLocalization(language: "ko")
        let menu = NSMenu()
        let localizer = AppMenuLocalizer(localization: localization, mainMenu: { menu })
        localizer.start()
        defer { localizer.stop() }

        let window = addMenu("Window", to: menu)
        let minimize = window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        await settleMenuUpdates()

        #expect(menu.items.first?.title == "윈도우")
        #expect(minimize.title == "최소화")
    }

    @discardableResult
    private func addMenu(_ title: String, to parent: NSMenu) -> NSMenu {
        let submenu = NSMenu(title: title)
        let item = parent.addItem(withTitle: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return submenu
    }

    private func settleMenuUpdates() async {
        // Both Observation and NSMenu notifications schedule work on the
        // main actor; let the run loop finish those deferred updates.
        try? await Task.sleep(for: .milliseconds(50))
    }
}
