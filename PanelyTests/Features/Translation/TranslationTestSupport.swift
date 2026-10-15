import CoreGraphics
import Foundation
import Testing
@testable import Panely

/// Hands out passes one at a time, so a test decides when background work
/// waiting on it moves on.
actor TranslationPermitGate {
    private var permits = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        if isOpen { return }
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release(_ count: Int = 1) {
        for _ in 0..<count {
            if waiters.isEmpty { permits += 1 } else { waiters.removeFirst().resume() }
        }
    }

    /// Let everything through from now on — call at the end so nothing is
    /// left suspended.
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// A stand-in for the on-device speech-level model: rewrites every line it
/// gets (marking it), one pass of the gate per line. Matching saves each page
/// as it's done, so this is a way to change a cached page's content in
/// place, page by page, without a translation job.
struct GatedSpeechLevelCorrector: SpeechLevelCorrecting {
    let gate: TranslationPermitGate

    func correct(_ translation: String, source: String) async -> String? {
        await gate.pass()
        return translation + "〃"
    }
}

/// A finished page of `bubbles` balloons whose originals are the same in
/// every language (so the popover's other languages line up), translated as
/// `label`.
func makeTranslationTestPage(pageIndex: Int, bubbles: Int = 3, label: String) -> TranslatedPage {
    TranslatedPage(
        imageWidth: 1000,
        imageHeight: 1500,
        bubbles: (0..<bubbles).map { index in
            TranslatedBubble(
                id: index,
                rect: CGRect(x: 100 + Double(index) * 250, y: 200 + Double(index) * 300, width: 120, height: 220),
                glyphSize: 30,
                isVertical: true,
                source: "原文\(pageIndex)-\(index)",
                // A failed balloon is cached as "".
                translation: index == 2 && label.hasSuffix("!") ? "" : "\(label) \(pageIndex)-\(index)",
                background: .white
            )
        }
    )
}
