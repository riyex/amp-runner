import SwiftUI
import AmpRunnerCore

/// Shown before a runner starts. Displays the resolved Amp executable path, full
/// argument list, and working directory. The app may launch that command through a
/// native lifecycle helper, but the visible command is still the Amp invocation the user can
/// paste into a terminal.
struct StartConfirmationView: View {
    let profile: RunnerProfile
    let command: ResolvedRunnerCommand

    /// `remember == true` sets the profile's "don't ask again" opt-out.
    var onStart: (Bool) -> Void
    var onCancel: () -> Void

    @State private var dontAskAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Start “\(profile.name)”?")
                .font(.headline)

            Text("Amp Runner will launch the following process as you, using the app's inherited environment and your existing Git, SSH, and Amp configuration.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    field("Executable", command.executableURL.path)
                    field("Working directory", command.workingDirectoryURL.path)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Arguments")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if command.arguments.isEmpty {
                            Text("(none)")
                                .font(.system(.caption, design: .monospaced))
                        } else {
                            ForEach(Array(command.arguments.enumerated()), id: \.offset) { _, argument in
                                Text(argument)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            Text(RunnerCommandBuilder.commandPreview(for: command))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Don't ask again for this profile", isOn: $dontAskAgain)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { onStart(dontAskAgain) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520)
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
