import SwiftUI
import Foundation
import AmpRunnerCore

/// Global PATH settings shared by every runner profile.
struct EnvironmentSettingsView: View {
    @ObservedObject var coordinator: RunnerCoordinator

    @State private var drafts: [DirectoryDraft] = []
    @State private var saveError: String?
    @State private var hasLoadedPersistedSettings = false

    private let homeDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path

    private struct DirectoryDraft: Identifiable {
        let id = UUID()
        var value: String
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Environment")
                        .font(.title2)
                    Text("Add directories to search before the inherited PATH. Changes apply to profiles after they restart.")
                        .foregroundStyle(.secondary)
                }

                GroupBox("User directories") {
                    VStack(alignment: .leading, spacing: 10) {
                        if drafts.isEmpty {
                            Text("No additional directories. Add one when a tool is installed outside the usual locations.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(drafts.enumerated()), id: \.element.id) { index, draft in
                                directoryRow(draft, at: index)
                            }
                        }

                        Button {
                            drafts.append(DirectoryDraft(value: ""))
                            saveIfValid()
                        } label: {
                            Label("Add Directory", systemImage: "plus")
                        }
                        .help("Add a directory to the beginning of the runner PATH")
                    }
                    .padding(.vertical, 4)
                }

                if let saveError {
                    Text(saveError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                GroupBox("Effective PATH") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("User directories are searched first, followed by the inherited PATH and existing standard developer directories.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Restart running profiles to apply changes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 3) {
                                ForEach(coordinator.resolvedRunnerPath(for: drafts.map(\.value)).directories, id: \.self) { directory in
                                    Text(directory)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(minHeight: 100, maxHeight: 180)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding()
            .frame(minWidth: 660, alignment: .leading)
        }
        .frame(minWidth: 660, minHeight: 460)
        .onAppear(perform: loadPersistedSettingsIfNeeded)
    }

    @ViewBuilder
    private func directoryRow(_ draft: DirectoryDraft, at index: Int) -> some View {
        let status = status(for: draft.value)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Directory path", text: directoryBinding(for: draft.id))
                    .font(.system(.body, design: .monospaced))

                Button {
                    moveDraft(from: index, to: index - 1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Move directory up")
                .help("Move directory up")
                .disabled(index == 0)

                Button {
                    moveDraft(from: index, to: index + 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Move directory down")
                .help("Move directory down")
                .disabled(index == drafts.indices.last)

                Button(role: .destructive) {
                    drafts.remove(at: index)
                    saveIfValid()
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove directory")
                .help("Remove directory")
            }

            switch status {
            case .valid:
                EmptyView()
            case .missing(let normalizedPath):
                Text("Directory does not currently exist: \(normalizedPath). It will be preserved and used if created later.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .invalid(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func directoryBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { drafts.first(where: { $0.id == id })?.value ?? "" },
            set: { newValue in
                guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
                drafts[index].value = newValue
                saveIfValid()
            }
        )
    }

    private func status(for directory: String) -> RunnerPathEntryStatus {
        RunnerPathResolver.status(
            of: directory,
            homeDirectoryPath: homeDirectoryPath,
            directoryExists: directoryExists
        )
    }

    private func directoryExists(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func moveDraft(from source: Int, to destination: Int) {
        guard drafts.indices.contains(source), drafts.indices.contains(destination) else { return }
        let draft = drafts.remove(at: source)
        drafts.insert(draft, at: destination)
        saveIfValid()
    }

    private func saveIfValid() {
        guard drafts.allSatisfy({
            switch status(for: $0.value) {
            case .valid, .missing: return true
            case .invalid: return false
            }
        }) else {
            return
        }

        let directories = drafts.map(\.value)
        guard directories != coordinator.pathSettings.userDirectories else { return }

        do {
            try coordinator.savePathDirectories(directories)
            saveError = nil
        } catch {
            saveError = "Could not save PATH settings: \(error.localizedDescription)"
        }
    }

    private func loadPersistedSettingsIfNeeded() {
        guard !hasLoadedPersistedSettings else { return }
        hasLoadedPersistedSettings = true
        drafts = coordinator.pathSettings.userDirectories.map(DirectoryDraft.init(value:))
        saveError = nil
    }
}
