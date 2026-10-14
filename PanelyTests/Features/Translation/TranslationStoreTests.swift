import CoreGraphics
import Foundation
import Testing
@testable import Panely

func makeTranslatedPage(_ text: String = "번역", width: Double = 10, height: Double = 10) -> TranslatedPage {
    TranslatedPage(
        imageWidth: width,
        imageHeight: height,
        bubbles: [
            TranslatedBubble(
                id: 0,
                rect: CGRect(x: 1, y: 2, width: 3, height: 4),
                glyphSize: 2,
                isVertical: true,
                source: "原文",
                translation: text,
                background: BubbleBackground(red: 0.5, green: 0.4, blue: 0.3, isUniform: false)
            ),
        ]
    )
}

func makeTemporaryTranslationStore() throws -> TranslationStore {
    TranslationStore(root: try Fixture.makeTempDir().appendingPathComponent("translations", isDirectory: true))
}

struct TranslationStoreTests {
    @Test func savedPagesRoundTrip() throws {
        let store = try makeTemporaryTranslationStore()
        let key = TranslationStore.key(pageID: "file:/a.png#1:2", from: .japanese, to: .korean)

        try store.save(makeTranslatedPage(), key: key)

        #expect(store.load(key: key) == makeTranslatedPage())
        #expect(store.sizeBytes() > 0)
    }

    @Test func keyDependsOnPageAndLanguagePair() {
        let base = TranslationStore.key(pageID: "p1", from: .japanese, to: .korean)
        #expect(base == TranslationStore.key(pageID: "p1", from: .japanese, to: .korean))
        #expect(base != TranslationStore.key(pageID: "p2", from: .japanese, to: .korean))
        #expect(base != TranslationStore.key(pageID: "p1", from: .japanese, to: .english))
        #expect(base != TranslationStore.key(pageID: "p1", from: .chineseSimplified, to: .korean))
        // Accurate keeps the key from before modes existed; fast has its own.
        #expect(base == TranslationStore.key(pageID: "p1", from: .japanese, to: .korean, mode: .accurate))
        #expect(base != TranslationStore.key(pageID: "p1", from: .japanese, to: .korean, mode: .fast))
    }

    @Test func missingOrCorruptEntriesLoadAsNil() throws {
        let store = try makeTemporaryTranslationStore()
        #expect(store.load(key: "missing") == nil)

        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.root.appendingPathComponent("broken.json"))
        #expect(store.load(key: "broken") == nil)
    }

    @Test func clearRemovesEverything() throws {
        let store = try makeTemporaryTranslationStore()
        try store.save(makeTranslatedPage(), key: "a")
        try store.save(makeTranslatedPage(), key: "b")

        let removed = store.clear()

        #expect(removed > 0)
        #expect(store.sizeBytes() == 0)
        #expect(store.load(key: "a") == nil)
    }
}
