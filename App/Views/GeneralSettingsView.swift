import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var coordinator: RunnerCoordinator

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Start Amp Runner at Login", isOn: launchAtLoginBinding)
                if coordinator.launchAtLogin.requiresApproval {
                    Label("Login item needs approval in System Settings › General › Login Items", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Notifications") {
                Toggle("Notify on Thread Start / Finish / Failure", isOn: notificationBinding)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 520, minHeight: 360)
        .onAppear { coordinator.launchAtLogin.refresh() }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { coordinator.launchAtLogin.isEnabled }, set: { _ = coordinator.launchAtLogin.setEnabled($0) })
    }

    private var notificationBinding: Binding<Bool> {
        Binding(get: { coordinator.notifier.isEnabled }, set: { coordinator.notifier.isEnabled = $0 })
    }
}
