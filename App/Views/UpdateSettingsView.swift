import SwiftUI
import AmpRunnerCore

struct AmpExecutableRowPresentation: Equatable {
    let versionText: String
    let errorText: String?

    init(version: AmpVersion?, probeError: String?, installState: AmpExecutableInstallState?) {
        versionText = version.map { "Amp \($0)" } ?? "Amp version unknown"
        if case let .failed(message) = installState {
            errorText = message
        } else {
            errorText = probeError
        }
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var coordinator: RunnerCoordinator
    @State private var preferenceError: String?
    @State private var confirmsImmediateRestart = false

    var body: some View {
        Form {
            Section("Automatic Updates") {
                preferenceToggle("Automatically check for updates", keyPath: \.automaticallyChecksForUpdates)
                preferenceToggle("Automatically install updates", keyPath: \.automaticallyInstallsUpdates)
                    .padding(.leading, 20)
                preferenceToggle("Restart updated runners when idle", keyPath: \.restartsUpdatedRunnersWhenIdle)
                    .padding(.leading, 20)
                preferenceToggle("Notify when updates are available", keyPath: \.sendsUpdateNotifications)
                if let preferenceError {
                    Text(preferenceError)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .help(preferenceError)
                }
            }

            Section("Status") {
                LabeledContent("Latest Amp", value: coordinator.ampUpdateController.latestVersion.map(String.init(describing:)) ?? "Unknown")
                LabeledContent("Last checked", value: coordinator.ampUpdateController.lastCheckedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                if let error = coordinator.ampUpdateController.checkError {
                    Text(error).foregroundStyle(.red).lineLimit(3)
                }
            }

            Section("Amp Executables") {
                if coordinator.ampUpdateController.registeredExecutableURLs.isEmpty {
                    Text("No Amp executables are used by configured runners.").foregroundStyle(.secondary)
                } else {
                    ForEach(coordinator.ampUpdateController.registeredExecutableURLs, id: \.path) { url in
                        executableRow(url)
                    }
                }
            }

            Section {
                HStack {
                    Button("Check Now") { Task { await coordinator.ampUpdateController.checkNow() } }
                        .disabled(coordinator.ampUpdateController.checkState == .checking)
                    Button("Install Now") { coordinator.installAvailableUpdate() }
                        .disabled(!coordinator.canInstallAvailableUpdate)
                    Spacer()
                    Button("Restart All When Idle") { coordinator.restartAllWhenIdle() }
                        .disabled(coordinator.restartRequiredRunnerCount == 0)
                    Button("Restart All Now…", role: .destructive) { restartAllNow() }
                        .disabled(coordinator.restartRequiredRunnerCount == 0)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 660, minHeight: 460)
        .alert("Restart all updated runners now?", isPresented: $confirmsImmediateRestart) {
            Button("Cancel", role: .cancel) {}
            Button("Restart All Now", role: .destructive) { coordinator.restartAllNow() }
        } message: {
            Text("\(coordinator.workingRestartRequiredRunnerCount) affected runner(s) are working. Active work may be interrupted.")
        }
    }

    private func preferenceToggle(_ title: String, keyPath: WritableKeyPath<AmpUpdatePreferences, Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { coordinator.updatePreferences[keyPath: keyPath] },
            set: { value in
                var preferences = coordinator.updatePreferences
                preferences[keyPath: keyPath] = value
                do { try coordinator.saveUpdatePreferences(preferences); preferenceError = nil }
                catch { preferenceError = error.localizedDescription }
            }
        ))
    }

    private func executableRow(_ url: URL) -> some View {
        let path = url.standardizedFileURL.path
        let presentation = AmpExecutableRowPresentation(
            version: coordinator.ampUpdateController.installedVersions[path],
            probeError: coordinator.ampUpdateController.probeErrors[path],
            installState: coordinator.ampUpdateController.installStates[path]
        )
        return VStack(alignment: .leading, spacing: 3) {
            Text(path).lineLimit(1).truncationMode(.middle).help(path)
            Text(presentation.versionText)
                .font(.caption).foregroundStyle(.secondary)
            if let usage = coordinator.ampUpdateController.registeredExecutableUsage[path] {
                Text(executableUsageText(usage))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = presentation.errorText {
                Text(error)
                    .font(.caption).foregroundStyle(.red).lineLimit(3).help(error)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func executableUsageText(_ usage: AmpExecutableUsage) -> String {
        let runners = "Used by \(usage.runnerCount) runner\(usage.runnerCount == 1 ? "" : "s")"
        guard usage.alternatePathCount > 0 else { return runners }
        let paths = "\(usage.alternatePathCount) via alternate path\(usage.alternatePathCount == 1 ? "" : "s")"
        return "\(runners); \(paths)"
    }

    private func restartAllNow() {
        if coordinator.workingRestartRequiredRunnerCount > 0 { confirmsImmediateRestart = true }
        else { coordinator.restartAllNow() }
    }
}
