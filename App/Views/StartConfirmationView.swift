import SwiftUI
import AmpRunnerCore

/// Shown before a runner starts. Displays the **exact** resolved executable path, the
/// full argument list, and the resolved working directory — the same
/// `ResolvedRunnerCommand` value that will be handed to `Process`, so what is shown
/// cannot drift from what is run.
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

            Text("Amp Runner will launch the following process as you, in your normal login session. It inherits your environment, so it can use your existing Git, SSH, and Amp configuration exactly as if you ran it in Terminal.")
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
