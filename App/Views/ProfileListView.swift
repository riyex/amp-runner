import SwiftUI
import AmpRunnerCore

/// Profile list with add / duplicate / delete, hosted in the Settings scene.
struct ProfileListView: View {
    @ObservedObject var coordinator: RunnerCoordinator

    @State private var selection: UUID?
    @State private var editingDraft: EditingDraft?
    @State private var errorMessage: String?
    @State private var deletionCandidate: RunnerProfile?

    /// A draft plus the folder the picker should start at.
    struct EditingDraft: Identifiable {
        let id = UUID()
        var profile: RunnerProfile
        var suggestedDirectory: URL?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if coordinator.profiles.isEmpty {
                emptyState
            } else {
                List(coordinator.profiles, selection: $selection) { profile in
                    row(for: profile)
                        .tag(profile.id)
                }
                .listStyle(.inset)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Add") { editingDraft = EditingDraft(profile: coordinator.makeDraftProfile()) }
                Button("Duplicate") { duplicateSelected() }
                    .disabled(selectedProfile == nil)
                Button("Delete") { deletionCandidate = selectedProfile }
                    .disabled(selectedProfile == nil)
                Spacer()
                Button("Edit…") { editSelected() }
                    .disabled(selectedProfile == nil)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 360)
        .sheet(item: $editingDraft) { draft in
            ProfileEditorView(
                coordinator: coordinator,
                draft: draft.profile,
                suggestedDirectory: draft.suggestedDirectory,
                onSave: { saved in
                    save(saved)
                    editingDraft = nil
                },
                onCancel: { editingDraft = nil }
            )
        }
        .alert(
            "Delete “\(deletionCandidate?.name ?? "")”?",
            isPresented: Binding(
                get: { deletionCandidate != nil },
                set: { if !$0 { deletionCandidate = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { deletionCandidate = nil }
            Button("Delete", role: .destructive) {
                if let candidate = deletionCandidate { delete(candidate) }
                deletionCandidate = nil
            }
        } message: {
            Text("This removes the profile from Amp Runner. Nothing in the working directory is touched.")
        }
        .onAppear { consumeDraftRequest() }
        .onChange(of: coordinator.draftRequest) { _ in consumeDraftRequest() }
    }

    // MARK: - Pieces

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No runner profiles yet")
                .font(.headline)
            Text("A profile supervises one `amp --no-tui` process in one directory of your choosing. Nothing runs until you pick that folder yourself.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Create “SampleProject” Profile") { startSampleProjectQuickStart() }
                Button("New Profile") {
                    editingDraft = EditingDraft(profile: coordinator.makeDraftProfile())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    private func row(for profile: RunnerProfile) -> some View {
        let status = coordinator.status(for: profile)
        return HStack(spacing: 10) {
            Circle()
                .fill(color(for: status))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .fontWeight(.medium)
                Text(profile.workingDirectoryPath.isEmpty ? "No folder chosen" : profile.workingDirectoryPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(status.detailedDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            if status.isRunning {
                Button("Stop") { coordinator.stop(profile) }
            } else {
                Button("Start") { coordinator.requestStart(profile) }
            }
        }
        .padding(.vertical, 2)
    }

    private func color(for status: RunnerStatus) -> Color {
        switch status {
        case .stopped: return .secondary
        case .starting: return .yellow
        case .online: return .green
        case .working: return .blue
        case .error: return .red
        }
    }

    // MARK: - Actions

    private var selectedProfile: RunnerProfile? {
        guard let selection else { return nil }
        return coordinator.profiles.first { $0.id == selection }
    }

    private func editSelected() {
        guard let selectedProfile else { return }
        editingDraft = EditingDraft(profile: selectedProfile)
    }

    private func duplicateSelected() {
        guard let selectedProfile else { return }
        editingDraft = EditingDraft(profile: coordinator.makeDuplicateDraft(of: selectedProfile))
    }

    private func startSampleProjectQuickStart() {
        editingDraft = EditingDraft(
            profile: coordinator.makeSampleProjectDraft(),
            suggestedDirectory: coordinator.sampleProjectSuggestedDirectory
        )
    }

    private func save(_ profile: RunnerProfile) {
        do {
            try coordinator.persist(profile)
            selection = profile.id
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func delete(_ profile: RunnerProfile) {
        do {
            try coordinator.delete(profile)
            if selection == profile.id { selection = nil }
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Turns a request made from the menu bar into an open editor, exactly once.
    private func consumeDraftRequest() {
        switch coordinator.draftRequest {
        case .none:
            return
        case .new:
            editingDraft = EditingDraft(profile: coordinator.makeDraftProfile())
        case .sampleProject:
            startSampleProjectQuickStart()
        case .edit(let id):
            if let profile = coordinator.profiles.first(where: { $0.id == id }) {
                editingDraft = EditingDraft(profile: profile)
            }
        case .duplicate(let id):
            if let profile = coordinator.profiles.first(where: { $0.id == id }) {
                editingDraft = EditingDraft(profile: coordinator.makeDuplicateDraft(of: profile))
            }
        }
        coordinator.draftRequest = .none
    }
}
