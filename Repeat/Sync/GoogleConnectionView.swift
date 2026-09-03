import SwiftUI
import GoogleSheets

/// The Google section of Settings (§6.6). Lives on its own so #25 can embed it
/// and #24's first-run setup sheet can present the same thing.
struct GoogleConnectionView: View {
    @Bindable var settings: SheetsSettings

    @State private var pastedKey = ""
    @State private var isEditingKey = false
    @State private var checkResult: CheckResult?
    @State private var isChecking = false

    private enum CheckResult: Equatable {
        case ok(String)
        case failed(String)
    }

    var body: some View {
        Group {
            Section("Google") {
                statusRow

                if isEditingKey || !settings.isConfigured {
                    // Secure, so the key is not shoulder-readable and never
                    // enters the keyboard's learned text. Single-line by
                    // necessity — SecureField has no multi-line form — which
                    // costs nothing here, since the key arrives by paste.
                    SecureField("Вставте JSON ключа службового акаунта", text: $pastedKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Зберегти ключ") { saveKey() }
                        .disabled(pastedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button("Замінити ключ") { isEditingKey = true }
                }

                TextField("ID таблиці або її посилання", text: $settings.spreadsheetId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        settings.spreadsheetId = SheetsSettings.extractSpreadsheetId(from: settings.spreadsheetId)
                    }

                Button {
                    Task { await check() }
                } label: {
                    HStack {
                        Text("Перевірити зʼєднання")
                        if isChecking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(!settings.isConfigured || isChecking)

                if let checkResult {
                    switch checkResult {
                    case .ok(let message):
                        Label(message, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Palette.accent)
                            .font(.footnote)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.again)
                            .font(.footnote)
                    }
                }
            }

            if settings.isConfigured {
                Section {
                    Button("Видалити ключ", role: .destructive) {
                        settings.removeKey()
                        checkResult = nil
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch settings.status {
        case .notConfigured:
            Label("Ключ не додано", systemImage: "key.slash")
                .foregroundStyle(Palette.ink2)
        case .configured(let summary):
            // Masked: enough to tell which account is configured, nothing that
            // helps use it (§6.6).
            LabeledContent("Службовий акаунт", value: summary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.again)
                .font(.footnote)
        }
    }

    private func saveKey() {
        switch settings.saveKey(json: pastedKey) {
        case .success(let account):
            pastedKey = ""
            isEditingKey = false
            checkResult = .ok(Localized.string("Ключ збережено для \(account.maskedSummary)"))
        case .failure(let error):
            checkResult = .failed(String(describing: error))
        }
    }

    private func check() async {
        settings.spreadsheetId = SheetsSettings.extractSpreadsheetId(from: settings.spreadsheetId)
        isChecking = true
        defer { isChecking = false }
        switch await settings.checkConnection() {
        case .success(let message): checkResult = .ok(message)
        case .failure(let error): checkResult = .failed(String(describing: error))
        }
    }
}
