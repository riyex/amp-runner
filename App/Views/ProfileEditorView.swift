import SwiftUI
import AppKit
import AmpRunnerCore

/// Create/edit form for a single profile.
struct ProfileEditorView: View {
    @ObservedObject var coordinator: RunnerCoordinator

    /// Working copy. Nothing is persisted until Save succeeds.
    @State var draft: RunnerProfile

    /// Directory to open the folder picker at, when the caller has a suggestion.
    /// Access is still only granted by the user's own pick.
    var suggestedDirectory: URL?

    var onSave: (RunnerProfile) -> Void
    var onCancel: () -> Void

    @State private var validationMessage: String?
    @State private var argumentsText: String = ""
    @State private var lastSyncedRunnerID: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Identity") {
                    TextField("Name", text: $draft.name)
                    TextField("Runner ID", text: $draft.runnerID)
                        .onChange(of: draft.runnerID) { _, _ in
                            syncDefaultArgumentsIfUnmodified()
                        }
                    Text("Amp identifies a runner by host plus working directory. The runner ID labels it for you and is passed through as --runner-id.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Working Directory") {
                    HStack {
                        Text(draft.workingDirectoryPath.isEmpty ? "No folder chosen" : draft.workingDirectoryPath)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(draft.workingDirectoryPath.isEmpty ? .secondary : .primary)
                        Spacer()
                        Button("Choose…") { chooseWorkingDirectory() }
                    }
                    Text("Must be chosen explicitly. Each profile needs its own isolated directory — two runners cannot share one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Amp Executable") {
                    HStack {
                        TextField("Path to amp", text: $draft.ampExecutablePath)
                            .font(.system(.body, design: .monospaced))
                        Button("Detect") { detectAmpPath() }
                    }
                }

                Section("Arguments") {
                    TextEditor(text: $argumentsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 72)
                        .onChange(of: argumentsText) { _, newValue in
                            draft.arguments = Self.parseArguments(newValue)
                        }
                    HStack {
                        Text("One argument per line.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset to Default") {
                            let runnerID = draft.runnerID.trimmingCharacters(in: .whitespacesAndNewlines)
                            draft.arguments = RunnerProfile.defaultArguments(runnerID: runnerID)
                            argumentsText = Self.formatArguments(draft.arguments)
                            lastSyncedRunnerID = runnerID
                        }
                        .buttonStyle(.link)
                    }
                }

                Section("Behaviour") {
                    Toggle("Start this runner automatically when Amp Runner launches", isOn: $draft.autoStart)
                    Toggle("Always show start confirmation", isOn: $draft.confirmBeforeStart)
                    if !draft.confirmBeforeStart {
                        Text("With confirmation off, Start launches Amp immediately with the resolved settings below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Terminal Equivalent") {
                    Text(coordinator.commandPreview(for: draft))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            if let validationMessage {
                Text(validationMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.top, 4)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 560)
        .onAppear {
            argumentsText = Self.formatArguments(draft.arguments)
            lastSyncedRunnerID = draft.runnerID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Actions

    private func save() {
        do {
            try RunnerProfileStore.validateCandidate(draft, against: coordinator.profiles)
            _ = try RunnerCommandBuilder.resolve(
                profile: draft,
                homeDirectoryPath: FileManager.default.homeDirectoryForCurrentUser.path
            )
            validationMessage = nil
            onSave(draft)
        } catch let error as RunnerProfileValidationError {
            validationMessage = error.description
        } catch let error as RunnerCommandBuilderError {
            validationMessage = error.description
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    /// The only way a working directory is ever set. Never defaults silently.
    private func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder this Amp runner will execute in."
        if let suggestedDirectory,
           FileManager.default.fileExists(atPath: suggestedDirectory.path) {
            panel.directoryURL = suggestedDirectory
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.workingDirectoryPath = url.path
        // Keep folder access across relaunches; harmless when not sandboxed.
        coordinator.bookmarks.storeBookmark(for: url, profileID: draft.id)
        validationMessage = nil
    }

    private func detectAmpPath() {
        if let path = RunnerCoordinator.detectAmpExecutablePath() {
            draft.ampExecutablePath = path
            validationMessage = nil
        } else {
            validationMessage = "Could not find amp in AMP_HOME, ~/.amp/bin, PATH, Homebrew, ~/.local/bin, ~/bin, or ~/.bin. Install it with: curl -fsSL https://ampcode.com/install.sh | bash"
        }
    }

    /// Keeps `--runner-id <id>` in step while the user is still using the default
    /// argument list, and leaves hand-edited lists alone.
    private func syncDefaultArgumentsIfUnmodified() {
        let trimmedRunnerID = draft.runnerID.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { lastSyncedRunnerID = trimmedRunnerID }

        let previousDefaultArguments = RunnerProfile.defaultArguments(runnerID: lastSyncedRunnerID)
        guard draft.arguments == previousDefaultArguments else { return }

        draft.arguments = RunnerProfile.defaultArguments(runnerID: trimmedRunnerID)
        argumentsText = Self.formatArguments(draft.arguments)
    }

    static func formatArguments(_ arguments: [String]) -> String {
        arguments.joined(separator: "\n")
    }

    static func parseArguments(_ text: String) -> [String] {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
