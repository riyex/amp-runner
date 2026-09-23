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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Identity") {
                    TextField("Name", text: $draft.name)
                    TextField("Runner ID", text: $draft.runnerID)
                        .onChange(of: draft.runnerID) { _, newValue in
                            draft.syncRunnerID(newValue)
                        }
                    Text("One runner can serve many repositories and directories. Use a unique runner ID for each process.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Launch Directory") {
                    HStack {
                        Text(draft.workingDirectoryPath.isEmpty ? "No folder chosen" : draft.workingDirectoryPath)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(draft.workingDirectoryPath.isEmpty ? .secondary : .primary)
                        Spacer()
                        Button("Choose…") { chooseWorkingDirectory() }
                    }
                    Text("Amp remembers live-added directories here and creates new projects beneath this folder. Each runner needs its own launch directory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                RunnerDirectorySourcesView(draft: $draft, bookmarks: coordinator.bookmarks)

                Section("Amp Environment") {
                    Toggle("Use Amp Secrets & Env Vars", isOn: $draft.usesAmpEnvironment)
                    Text("Adds --amp-env. Amp fetches personal, project, and workspace variables for threads, MCP servers, and plugins. This app does not store their values. When off, Amp’s own settings can still enable them.")
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

                DisclosureGroup("Advanced Arguments") {
                    TextEditor(text: Binding(
                        get: { Self.formatArguments(draft.arguments) },
                        set: { draft.arguments = Self.parseArguments($0) }
                    ))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 72)
                    HStack {
                        Text("One argument per line. Includes the options above.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset to Default") {
                            let runnerID = draft.runnerID.trimmingCharacters(in: .whitespacesAndNewlines)
                            draft.arguments = RunnerProfile.defaultArguments(runnerID: runnerID)
                        }
                        .buttonStyle(.link)
                    }
                }

                Section("Behaviour") {
                    Text("Amp runners update themselves. Amp Runner does not check for releases or restart runners to update them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

            if coordinator.status(for: draft).isRunning {
                Text("Saved launch settings apply on the next start. Use Directories… for live additions and removals.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

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
        .frame(minWidth: 600, minHeight: 680)
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
