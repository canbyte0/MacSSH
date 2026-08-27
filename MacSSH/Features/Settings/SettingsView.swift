import SwiftUI

/// Phase 1 的只读 Settings Mock 页面，不保存或应用任何偏好设置。
struct SettingsView: View {
    var body: some View {
        Form {
            Section("General") {
                LabeledContent("Launch Behavior", value: "Open Main Window")
                LabeledContent("Confirm Before Closing SSH", value: "On")
            }

            Section("Terminal") {
                LabeledContent("Font", value: "System Monospaced")
                LabeledContent("Font Size", value: "13 pt")
                LabeledContent("Scrollback", value: "10,000 lines")
            }

            Section("Appearance") {
                LabeledContent("Mode", value: "System")
            }

            Section("SSH") {
                LabeledContent("Connection Timeout", value: "10 seconds")
                LabeledContent("KeepAlive", value: "On")
            }

            Section {
                Text("Phase 1 values are read-only mock data and are not persisted.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .accessibilityIdentifier("workspace.settings")
    }
}
