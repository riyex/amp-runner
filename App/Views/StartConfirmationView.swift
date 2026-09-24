import SwiftUI
import AmpRunnerCore

/// Shown before a runner starts. Displays the resolved Amp executable path, full
/// argument list, and working directory handed to the native lifecycle helper.
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

            Text("Amp Runner will launch Amp through its native monitor helper, using the app's inherited environment and your existing Git, SSH, and Amp configuration.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if profile.sharesWithWorkspace {
                Label {
                    Text("This runner is shared. Trusted workspace members can run code on this Mac as you, read and change your files, and use your credentials and logins.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.orange.opacity(0.35))
                }
            }

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
