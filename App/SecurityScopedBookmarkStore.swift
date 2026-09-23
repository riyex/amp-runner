import Foundation

/// Persists security-scoped bookmarks for each profile's selected directories so folder
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
    private var activeURLs: [String: URL] = [:]

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
    func storeBookmark(for url: URL, profileID: UUID, additionalDirectory: Bool = false) {
        let key = profileID.uuidString + (additionalDirectory ? ":" + url.path : "")
        storeBookmark(for: url, key: key)
        _ = startAccessing(key: key)
    }

    private func storeBookmark(for url: URL, key: String) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var updated = bookmarks
            updated[key] = data
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
        for key in updated.keys where belongs(key, to: profileID) {
            updated.removeValue(forKey: key)
        }
        bookmarks = updated
    }

    // MARK: - Access

    /// Resolves the stored bookmark and begins security-scoped access. Returns the
    /// resolved URL, or `nil` when there is no usable bookmark.
    @discardableResult
    func startAccessing(profileID: UUID) -> URL? {
        startAccessing(key: profileID.uuidString)
    }

    private func startAccessing(key: String) -> URL? {
        if let existing = activeURLs[key] { return existing }
        guard let data = bookmarks[key] else { return nil }

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
            NSLog("AmpRunner: could not resolve bookmark \(key): \(error)")
            return nil
        }

        // Succeeds trivially outside the sandbox; required inside it.
        guard url.startAccessingSecurityScopedResource() else { return nil }
        activeURLs[key] = url

        if isStale {
            storeBookmark(for: url, key: key)
        }
        return url
    }

    /// Called once on launch for every profile that has a stored bookmark.
    func startAccessingAll(profileIDs: [UUID]) {
        for id in profileIDs {
            for key in bookmarks.keys where belongs(key, to: id) {
                _ = startAccessing(key: key)
            }
        }
    }

    func stopAccessing(profileID: UUID) {
        for key in activeURLs.keys where belongs(key, to: profileID) {
            activeURLs.removeValue(forKey: key)?.stopAccessingSecurityScopedResource()
        }
    }

    private func belongs(_ key: String, to profileID: UUID) -> Bool {
        key == profileID.uuidString || key.hasPrefix(profileID.uuidString + ":")
    }

    func stopAccessingAll() {
        for (_, url) in activeURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeURLs.removeAll()
    }
}
