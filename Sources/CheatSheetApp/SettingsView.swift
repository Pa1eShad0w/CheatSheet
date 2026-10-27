import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "command.square.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(text("app.name")).font(.title2.bold())
                    Text(text("settings.introduction"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            GroupBox {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: model.isTrusted ? "checkmark.shield.fill" : "lock.shield")
                        .font(.title2)
                        .foregroundStyle(model.isTrusted ? Color.green : Color.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(text(model.isTrusted ? "permission.granted" : "permission.required"))
                            .font(.headline)
                        Text(text("permission.explanation"))
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button(text(model.isTrusted ? "permission.open" : "permission.allow")) {
                                if model.isTrusted {
                                    model.openAccessibilitySettings()
                                } else {
                                    model.requestAccessibility()
                                }
                            }
                            Button(text("permission.recheck")) { model.refreshPermissions() }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
            }

            Form {
                Toggle(text("settings.enabled"), isOn: $model.isEnabled)
                LabeledContent(text("settings.delay")) {
                    HStack {
                        Slider(value: $model.holdDelay, in: 0.4...2.0, step: 0.1)
                            .frame(width: 180)
                            .accessibilityLabel(text("settings.delay"))
                        Text(model.holdDelay.formatted(.number.precision(.fractionLength(1))) + " s")
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle(
                    text("settings.login"),
                    isOn: Binding(
                        get: { model.loginStatus == .enabled || model.loginStatus == .requiresApproval },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                if model.loginStatus == .requiresApproval {
                    Button(text("settings.loginApproval")) {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: model.loginStatus == .requiresApproval ? 195 : 155)

            if model.monitorUnavailable {
                Label(text("settings.monitorUnavailable"), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let error = model.loginError {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(text("settings.instructions"))
                Text(text("settings.privacy"))
            }
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 540)
    }
}
