import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject private var launchAtLogin: LaunchAtLoginManager
    @ObservedObject private var notifier: RunnerNotifier

    init(coordinator: RunnerCoordinator) {
        launchAtLogin = coordinator.launchAtLogin
        notifier = coordinator.notifier
    }

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Start Amp Runner at Login", isOn: launchAtLoginBinding)
                if launchAtLogin.requiresApproval {
                    Label("Login item needs approval in System Settings › General › Login Items", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let error = launchAtLogin.lastError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .help(error)
                }
            }
            Section("Notifications") {
                Toggle("Notify on Thread Start / Finish / Failure", isOn: notificationBinding)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 520, minHeight: 360)
        .onAppear { launchAtLogin.refresh() }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { launchAtLogin.isEnabled }, set: { _ = launchAtLogin.setEnabled($0) })
    }

    private var notificationBinding: Binding<Bool> {
        Binding(get: { notifier.isEnabled }, set: { notifier.isEnabled = $0 })
    }
}
