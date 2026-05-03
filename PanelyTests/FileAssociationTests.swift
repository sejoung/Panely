import Testing
import Foundation
@testable import Panely

/// Verifies the Info.plist registrations that make Panely show up in Finder's
/// "Open With" menu for folders, .zip and .cbz files. A silent regression here
/// (typo in a UTI string, wrong LSHandlerRank) would not break the build but
/// would break the right-click flow — these tests catch that.
struct FileAssociationTests {

    private var info: [String: Any] {
        // TEST_HOST is set to Panely.app, so Bundle.main is the deployed app
        // bundle and reflects the real Info.plist that LaunchServices reads.
        Bundle.main.infoDictionary ?? [:]
    }

    private var documentTypes: [[String: Any]] {
        info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
    }

    private func documentType(forContentType type: String) -> [String: Any]? {
        documentTypes.first { entry in
            (entry["LSItemContentTypes"] as? [String])?.contains(type) ?? false
        }
    }

    // MARK: - CFBundleDocumentTypes

    @Test func registersFolderAsAlternateHandler() {
        // Folders must be Alternate, never Owner — taking ownership would
        // hijack Finder's default double-click-to-open-folder behavior.
        let entry = documentType(forContentType: "public.folder")
        #expect(entry != nil, "Missing CFBundleDocumentTypes entry for public.folder")
        #expect(entry?["LSHandlerRank"] as? String == "Alternate")
        #expect(entry?["CFBundleTypeRole"] as? String == "Viewer")
    }

    @Test func registersZipAsAlternateHandler() {
        // Zip is also Alternate so we don't displace Archive Utility as the
        // system default for .zip.
        let entry = documentType(forContentType: "public.zip-archive")
        #expect(entry != nil, "Missing CFBundleDocumentTypes entry for public.zip-archive")
        #expect(entry?["LSHandlerRank"] as? String == "Alternate")
    }

    @Test func registersCBZAsOwner() {
        // Panely declares the com.panely.cbz UTI itself, so it should claim
        // Owner rank — that's what makes it the default app for .cbz files.
        let entry = documentType(forContentType: "com.panely.cbz")
        #expect(entry != nil, "Missing CFBundleDocumentTypes entry for com.panely.cbz")
        #expect(entry?["LSHandlerRank"] as? String == "Owner")
    }

    // MARK: - UTImportedTypeDeclarations

    // MARK: - NSServices

    @Test func registersOpenInPanelyService() {
        // Folders don't surface in Finder's "Open With" submenu, so the
        // Services menu is the right-click entry point we expose for them.
        // A typo in NSMessage / NSPortName silently breaks the wire-up at
        // runtime — these checks fail loudly at build time instead.
        let services = info["NSServices"] as? [[String: Any]] ?? []
        let openService = services.first { service in
            let menu = service["NSMenuItem"] as? [String: String]
            return menu?["default"] == "Open in Panely"
        }

        #expect(openService != nil, "Missing 'Open in Panely' service in NSServices")

        // NSMessage must match the @objc selector on PanelyServiceProvider.
        // If the strings drift apart, AppKit will silently no-op the menu pick.
        #expect(openService?["NSMessage"] as? String == "openInPanely")
        #expect(openService?["NSPortName"] as? String == "Panely")

        let sendTypes = openService?["NSSendTypes"] as? [String] ?? []
        #expect(sendTypes.contains("public.file-url"))
    }

    @Test func declaresCBZUTIConformingToZip() {
        let imported = info["UTImportedTypeDeclarations"] as? [[String: Any]] ?? []
        let cbz = imported.first {
            $0["UTTypeIdentifier"] as? String == "com.panely.cbz"
        }

        #expect(cbz != nil, "com.panely.cbz UTI must be declared in UTImportedTypeDeclarations")

        // Conforming to public.zip-archive lets LaunchServices treat .cbz as
        // a zip variant — that's how Open With surfaces Panely as an option
        // even when other apps only register for the parent type.
        let conformsTo = cbz?["UTTypeConformsTo"] as? [String] ?? []
        #expect(conformsTo.contains("public.zip-archive"))

        let tags = cbz?["UTTypeTagSpecification"] as? [String: Any] ?? [:]
        let extensions = tags["public.filename-extension"] as? [String] ?? []
        #expect(extensions.contains("cbz"))
    }
}
