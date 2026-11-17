import SwiftUI

/// Settings ▸ AI: the provider, its key (kept in the Keychain), models, and inline suggestions.
struct AISettingsView: View {
    @Bindable var settings = AISettings.shared
    @State private var keyDraft = ""
    @State private var keyError: String?
    @State private var testResult: (ok: Bool, message: String)?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(AIProviderKind.allCases) { Text($0.title).tag($0) }
                }
                if settings.provider == .openAICompatible {
                    LabeledContent("Base URL") {
                        HStack(spacing: 6) {
                            TextField("", text: $settings.baseURL, prompt: Text("http://localhost:11434/v1"))
                                .font(.body.monospaced())
                            Menu("Presets") {
                                ForEach(OpenAICompatibleProvider.presets) { preset in
                                    Button("\(preset.name)  —  \(preset.baseURL)") { settings.baseURL = preset.baseURL }
                                }
                            }
                            .fixedSize()
                        }
                    }
                }
                apiKey
            } header: {
                Text("Provider")
            } footer: {
                Text(settings.provider == .claude
                     ? "Requests go to api.anthropic.com with your API key."
                     : "Any server with the OpenAI Chat Completions API. Local servers (Ollama, LM Studio) need no key.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Models") {
                if settings.provider == .claude {
                    TextField("Suggestions", text: $settings.claudeSuggestionModel,
                              prompt: Text(ClaudeProvider.defaultSuggestionModel))
                        .font(.body.monospaced())
                    TextField("Edits (⌘I)", text: $settings.claudeEditModel, prompt: Text(ClaudeProvider.defaultEditModel))
                        .font(.body.monospaced())
                } else {
                    TextField("Suggestions", text: $settings.openAISuggestionModel, prompt: Text("model name, e.g. qwen2.5-coder:7b"))
                        .font(.body.monospaced())
                    TextField("Edits (⌘I)", text: $settings.openAIEditModel, prompt: Text("empty: the suggestions model"))
                        .font(.body.monospaced())
                }
            }

            Section {
                Toggle("Show inline suggestions while typing", isOn: $settings.inlineSuggestionsEnabled)
                    .disabled(!settings.isConfigured && !settings.inlineSuggestionsEnabled)
                Stepper("Wait after typing: \(settings.debounceMilliseconds) ms", value: $settings.debounceMilliseconds,
                        in: AISettings.debounceRange, step: 50)
                HStack {
                    Button(isTesting ? "Testing…" : "Test") { runTest() }
                        .disabled(isTesting || !settings.isConfigured)
                    if let testResult {
                        Label(testResult.message, systemImage: testResult.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(testResult.ok ? .green : .orange)
                            .font(.caption)
                            .lineLimit(3)
                    } else if let problem = settings.configurationProblem {
                        Text(problem).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Inline Suggestions and Edits")
            } footer: {
                Text("Tab accepts a suggestion, ⌘→ its next word, Esc dismisses it; ⌥\\ asks for one. ⌘I edits the selection. The code around the cursor (and the selection, for edits) is sent to the chosen provider.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.provider) { keyDraft = ""; keyError = nil; testResult = nil }
    }

    /// The key is never shown: only whether one is saved.
    @ViewBuilder private var apiKey: some View {
        let provider = settings.provider
        LabeledContent(provider == .claude ? "API key" : "API key (optional)") {
            HStack(spacing: 6) {
                SecureField("", text: $keyDraft, prompt: Text(settings.hasKey(for: provider) ? "Saved in the Keychain" : "Paste a key"))
                    .onSubmit(saveKey)
                Button("Save", action: saveKey).disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                if settings.hasKey(for: provider) {
                    Button("Remove") {
                        do { try settings.removeKey(); keyError = nil } catch { keyError = error.localizedDescription }
                    }
                }
            }
        }
        if settings.hasKey(for: provider) {
            Label("Key saved in the Keychain", systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let keyError {
            Text(keyError).font(.caption).foregroundStyle(.orange)
        }
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try settings.saveKey(key)
            keyDraft = ""
            keyError = nil
            testResult = nil
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        Task {
            let result = await settings.test()
            isTesting = false
            switch result {
            case .success(let reply): testResult = (true, reply.isEmpty ? "Connected." : "Connected: “\(reply.prefix(40))”")
            case .failure(let error): testResult = (false, error.localizedDescription)
            }
        }
    }
}
