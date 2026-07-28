import Foundation

/// Persists one security-scoped bookmark per profile working directory so folder
/// access chosen in `NSOpenPanel` survives relaunch.
///
/// This is written to work identically whether or not the App Sandbox entitlement is
/// present. Outside the sandbox the bookmarks are harmless no-ops (the app already has
/// access); inside it they are the only way to keep the user's chosen folder reachable
/// after a restart. Keeping the code unconditional means the Developer-ID and
/// App Store targets share one code path.
@MainActor
final class SecurityScopedBookmarkStore {

    private let defaults: UserDefaults
    private let defaultsKey = "com.riyex.amprunner.workingDirectoryBookmarks"

    /// URLs currently being accessed, so `stopAccessingSecurityScopedResource()` can be
    /// balanced on teardown.
    private var activeURLs: [UUID: URL] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Storage

    private var bookmarks: [String: Data] {
        get { defaults.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:] }
        set { defaults.set(newValue, forKey: defaultsKey) }
    }

    /// Creates and stores a bookmark for a folder the user just picked.
    ///
    /// `.withSecurityScope` is only meaningful for sandboxed apps but is accepted by
    /// `bookmarkData` in both cases, so no conditional compilation is needed.
    func storeBookmark(for url: URL, profileID: UUID) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var updated = bookmarks
            updated[profileID.uuidString] = data
            bookmarks = updated
        } catch {
            // A missing bookmark degrades gracefully: unsandboxed builds still work,
            // sandboxed builds will simply re-prompt for the folder.
            NSLog("AmpRunner: could not create security-scoped bookmark for \(url.path): \(error)")
        }
    }

    func removeBookmark(profileID: UUID) {
        stopAccessing(profileID: profileID)
        var updated = bookmarks
        updated.removeValue(forKey: profileID.uuidString)
        bookmarks = updated
    }

    // MARK: - Access

    /// Resolves the stored bookmark and begins security-scoped access. Returns the
    /// resolved URL, or `nil` when there is no usable bookmark.
    @discardableResult
    func startAccessing(profileID: UUID) -> URL? {
        if let existing = activeURLs[profileID] { return existing }
        guard let data = bookmarks[profileID.uuidString] else { return nil }

        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            NSLog("AmpRunner: could not resolve bookmark for profile \(profileID): \(error)")
            return nil
        }

        // Succeeds trivially outside the sandbox; required inside it.
        guard url.startAccessingSecurityScopedResource() else { return nil }
        activeURLs[profileID] = url

        if isStale {
            storeBookmark(for: url, profileID: profileID)
        }
        return url
    }

    /// Called once on launch for every profile that has a stored bookmark.
    func startAccessingAll(profileIDs: [UUID]) {
        for id in profileIDs {
            startAccessing(profileID: id)
        }
    }

    func stopAccessing(profileID: UUID) {
        guard let url = activeURLs.removeValue(forKey: profileID) else { return }
        url.stopAccessingSecurityScopedResource()
    }

    func stopAccessingAll() {
        for (_, url) in activeURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeURLs.removeAll()
    }
}
