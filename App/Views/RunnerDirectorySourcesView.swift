import SwiftUI
import AppKit
import AmpRunnerCore

/// Launch-time sources. Live membership is owned by Amp, not this list.
struct RunnerDirectorySourcesView: View {
    @Binding var draft: RunnerProfile
    let bookmarks: SecurityScopedBookmarkStore

    var body: some View {
        Section("Repository Discovery") {
            Toggle("Discover repositories in the launch directory", isOn: $draft.discoversWorkingDirectory)
            Text("Finds Git checkouts up to two levels down, including their worktrees. New checkouts appear automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
            paths(draft.discoveryDirectoryPaths) { path in
                draft.discoveryDirectoryPaths.removeAll { $0 == path }
            }
            Button("Add Discovery Folders…") { choose(discovery: true) }
        }
        Section("Explicit Directories") {
            Toggle("Serve the launch directory itself", isOn: $draft.servesWorkingDirectory)
            paths(draft.servedDirectoryPaths) { path in
                draft.servedDirectoryPaths.removeAll { $0 == path }
            }
            Button("Add Directories…") { choose(discovery: false) }
            Text("Uses --dir for each folder. To serve only these folders, turn off discovery, remove discovery folders, and turn off serving the launch directory.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func paths(_ values: [String], remove: @escaping (String) -> Void) -> some View {
        ForEach(Array(values.enumerated()), id: \.offset) { _, path in
            HStack {
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                Spacer()
                Button { remove(path) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(path)")
            }
        }
    }

    private func choose(discovery: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = discovery ? "Choose folders to scan for Git repositories." : "Choose directories to serve directly."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if discovery {
                if !draft.discoveryDirectoryPaths.contains(url.path) {
                    draft.discoveryDirectoryPaths.append(url.path)
                }
            } else if !draft.servedDirectoryPaths.contains(url.path) {
                draft.servedDirectoryPaths.append(url.path)
            }
            bookmarks.storeBookmark(for: url, profileID: draft.id, additionalDirectory: true)
        }
    }
}
