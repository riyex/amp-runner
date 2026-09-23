import AmpRunnerCore
import AppKit
import SwiftUI

struct RunnerDirectoriesView: View {
    @ObservedObject var coordinator: RunnerCoordinator
    let profile: RunnerProfile
    var onEdit: () -> Void
    var onClose: () -> Void

    @State private var directoryPath = ""
    @State private var listing = ""
    @State private var message: String?
    @State private var failure: String?
    @State private var busy = false

    private var running: Bool { coordinator.status(for: profile).isRunning }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Directories — \(profile.name)").font(.title2)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("Refresh") { perform(.list) }
                        .disabled(!running || busy)
                }
                Text("Currently served by the running instance")
                    .font(.headline)
                ScrollView([.horizontal, .vertical]) {
                    Text(
                        running
                            ? (listing.isEmpty ? "Refresh to list directories." : listing)
                            : "This runner is stopped. Start it to list or change live directories."
                    )
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .frame(height: 150)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

                Text("Live additions").font(.headline)
                HStack {
                    TextField("Absolute directory path", text: $directoryPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button("Choose…") { chooseDirectory() }
                }
                .disabled(!running || busy)
                HStack {
                    Button("Add Directory") { mutate(add: true) }
                    Button("Remove Added Directory") { mutate(add: false) }
                }
                .disabled(
                    !running || busy
                        || directoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text(
                    "Add and remove take effect without restarting. Amp remembers live additions. Remove only undoes a live addition; it never deletes files."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()
                Text("Launch-configured and discovered directories")
                    .font(.headline)
                Text(
                    "Use Edit Launch Settings to change --dir entries or discovery roots. To exclude a discovered repository, add --discover-exclude and its pattern in Advanced Arguments. These changes require a restart. A directory may still be served by another source."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let message { Text(message).font(.caption).textSelection(.enabled) }
                if let failure {
                    Text(failure).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    Button("Edit Launch Settings…", action: onEdit).disabled(busy)
                    Spacer()
                    Button("Done", action: onClose)
                        .keyboardShortcut(.cancelAction)
                        .disabled(busy)
                }
            }
            .padding(20)
        }
        .frame(width: 620, height: 570)
        .onAppear { if running { perform(.list) } }
        .onChange(of: running) { _, _ in listing = "" }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        directoryPath = url.path
        coordinator.bookmarks.storeBookmark(
            for: url, profileID: profile.id, additionalDirectory: true)
    }

    private func mutate(add: Bool) {
        let path = RunnerCommandBuilder.expand(
            path: directoryPath,
            homeDirectoryPath: FileManager.default.homeDirectoryForCurrentUser.path)
        guard path.hasPrefix("/") else {
            failure = "Choose a folder or enter an absolute path."
            return
        }
        perform(add ? .add(path) : .remove(path))
    }

    private func perform(_ operation: RunnerDirectoryCommand.Operation) {
        guard !busy else { return }
        busy = true
        failure = nil
        message = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let output = try await coordinator.runDirectoryCommand(
                    operation, profileID: profile.id)
                if operation == .list {
                    listing = output
                } else {
                    message = output
                    // A successful mutation followed by a failed refresh must not be
                    // presented as a failed mutation or automatically retried.
                    listing = ""
                    do {
                        listing = try await coordinator.runDirectoryCommand(
                            .list, profileID: profile.id)
                    } catch {
                        failure =
                            "Directory change succeeded, but refresh failed: \(error.localizedDescription)"
                    }
                }
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
