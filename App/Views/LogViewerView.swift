import SwiftUI
import AppKit
import AmpRunnerCore

/// Tail of a runner's bounded in-memory log ring buffer.
struct LogViewerView: View {
    @ObservedObject var coordinator: RunnerCoordinator

    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { coordinator.logViewerProfileID ?? coordinator.profiles.first?.id },
            set: { coordinator.logViewerProfileID = $0 }
        )
    }

    private var selectedProfile: RunnerProfile? {
        guard let id = selectionBinding.wrappedValue else { return nil }
        return coordinator.profiles.first { $0.id == id }
    }

    private var lines: [String] {
        guard let id = selectedProfile?.id else { return [] }
        return coordinator.logLines(for: id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Runner", selection: selectionBinding) {
                    ForEach(coordinator.profiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)

                Spacer()

                if let profile = selectedProfile {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(coordinator.status(for: profile).detailedDescription)
                        if let summary = coordinator.threadSummary(for: profile) {
                            Text(summary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if coordinator.threadURLString(for: profile) != nil {
                        Button("Open Thread") { coordinator.openOnAmpCode(profile) }
                    }
                }
            }

            logBody

            HStack {
                Text("Showing the last \(ProcessSupervisor.logCapacity) lines.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { coordinator.copyToPasteboard(lines.joined(separator: "\n")) }
                    .disabled(lines.isEmpty)
                Button("Reveal Log File in Finder") {
                    if let id = selectedProfile?.id { coordinator.revealLogFileInFinder(id) }
                }
                .disabled(selectedProfile == nil)
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 400)
    }

    @ViewBuilder
    private var logBody: some View {
        if coordinator.profiles.isEmpty {
            placeholder("No runner profiles yet.")
        } else if lines.isEmpty {
            placeholder("No output yet. Start the runner to see its log here.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(6)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: lines.count) { _, count in
                    guard count > 0 else { return }
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
    }
}
