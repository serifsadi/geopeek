//
//  DefaultApplication.swift
//  GeoPeek
//
//  User-initiated default-app change for the content types declared in
//  Info.plist. Each type is handed to NSWorkspace.setDefaultApplication,
//  which shows the system consent dialog. Launch Services is never written
//  quietly, and LSHandlerRank stays Alternate.
//

import AppKit
import Observation
import UniformTypeIdentifiers

/// Makes this app the default handler for GeoJSON, KML, KMZ, and GPX.
///
/// `public.json` is intentionally absent. GeoPeek opens `.json` when the user
/// picks it, but it is not a declared document type and must not claim JSON.
@MainActor
@Observable
final class DefaultApplication {
    static let shared = DefaultApplication()

    /// True when this bundle is already the default for every content type that resolved.
    /// False when none resolved, so the missing-type alert can still be shown.
    private(set) var isDefaultForAll = false
    /// True while the consent dialogs are open, so a second click does not stack them.
    private(set) var isSetting = false
    /// The unresolved-type alert is shown once. Later clicks stay quiet.
    private var reportedMissingTypes = false

    /// Info.plist `LSItemContentTypes`, in the order the dialogs are shown.
    private static let typeIdentifiers = [
        "public.geojson",
        "com.google.earth.kml",
        "com.google.earth.kmz",
        "com.topografix.gpx",
    ]

    private init() {
        refresh()
    }

    func refresh() {
        // A refresh during the dialogs would hide the control before the
        // sequence's own refresh, and would read Launch Services mid-prompt.
        guard !isSetting else { return }
        let types = Self.contentTypes
        // Unresolved identifiers are left out. An empty list stays enabled.
        guard !types.isEmpty else {
            isDefaultForAll = false
            return
        }
        isDefaultForAll = types.allSatisfy(Self.isThisAppDefault)
    }

    /// Prompts once per type that is not already handled by this app.
    /// Dialogs run one after another. Cancelling one does not stop the rest,
    /// and a cancellation is not an error. Any other failure is shown once,
    /// after the remaining types have been asked.
    func setAsDefault() async {
        guard !isSetting else { return }
        let types = Self.contentTypes
        let missing = Self.typeIdentifiers.count - types.count
        if types.isEmpty {
            present("GeoPeek could not find the file types it opens.")
            return
        }
        let pending = types.filter { !Self.isThisAppDefault($0) }
        // Every resolved type is already this app. Refresh so a change made
        // elsewhere disables the control, and say so when a type never resolved.
        if pending.isEmpty {
            refresh()
            if missing > 0, !reportedMissingTypes {
                reportedMissingTypes = true
                present("GeoPeek could not find every file type it opens.")
            }
            return
        }
        isSetting = true
        defer {
            isSetting = false
            refresh()
        }

        var failure: String?
        for type in pending {
            do {
                try await NSWorkspace.shared.setDefaultApplication(
                    at: Bundle.main.bundleURL,
                    toOpen: type
                )
            } catch {
                if Self.isUserDenial(error) { continue }
                if failure == nil { failure = error.localizedDescription }
            }
        }
        if let failure {
            present(failure.isEmpty ? "GeoPeek could not become the default app." : failure)
        }
    }

    private static var contentTypes: [UTType] {
        typeIdentifiers.compactMap(UTType.init)
    }

    /// `urlForApplication(toOpen:)` is the default app Launch Services would use.
    /// Identity is this bundle's file, so a second copy of GeoPeek does not count.
    private static func isThisAppDefault(_ type: UTType) -> Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: type) else { return false }
        return isThisBundle(handler)
    }

    /// Path spelling, then the file itself. Launch Services may return this
    /// same bundle through `/System/Volumes/Data`. A different case of the
    /// same file matches through the file resource identifier. The path
    /// itself keeps its case, so another copy on a case-sensitive volume stays distinct.
    private static func isThisBundle(_ url: URL) -> Bool {
        let bundle = Bundle.main.bundleURL
        if normalizedPath(url) == normalizedPath(bundle) { return true }
        return sameFile(url, bundle)
    }

    private static func normalizedPath(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let dataRoot = "/System/Volumes/Data"
        if path.hasPrefix(dataRoot + "/") {
            path.removeFirst(dataRoot.count)
        }
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard
            let left = try? lhs.resourceValues(forKeys: keys).fileResourceIdentifier,
            let right = try? rhs.resourceValues(forKeys: keys).fileResourceIdentifier
        else { return false }
        return (left as AnyObject).isEqual(right)
    }

    /// The system dialog reports a refusal as a cancellation. That is the user
    /// choosing not to change the default, so it is not shown as an error.
    private static func isUserDenial(_ error: Error) -> Bool {
        if isDirectDenial(error) { return true }
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        return underlying.map(isDirectDenial) ?? false
    }

    private static func isDirectDenial(_ error: Error) -> Bool {
        if let cocoa = error as? CocoaError, cocoa.code == .userCancelled { return true }
        let nsError = error as NSError
        // userCanceledErr, when Launch Services reports the dismissal as an OSStatus.
        return nsError.domain == NSOSStatusErrorDomain && nsError.code == -128
    }

    private func present(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could Not Set the Default App"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
