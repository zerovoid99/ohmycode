import Foundation
import Observation
import Security

/// Where API keys are kept: the Keychain, or memory (tests).
@MainActor
protocol AIKeyStore: AnyObject {
    func key(for provider: AIProviderKind) -> String?
    /// Saves a key; nil or empty removes it.
    func setKey(_ key: String?, for provider: AIProviderKind) throws
}

/// API keys in the login Keychain, as generic passwords: one per provider.
@MainActor
final class KeychainKeyStore: AIKeyStore {
    static let service = "dev.zerovoid99.ohmycode.ai"

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "Keychain error \(status): " + ((SecCopyErrorMessageString(status, nil) as String?) ?? "unknown")
        }
    }

    private func query(_ provider: AIProviderKind) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: provider.rawValue]
    }

    func key(for provider: AIProviderKind) -> String? {
        var query = query(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setKey(_ key: String?, for provider: AIProviderKind) throws {
        let base = query(provider)
        guard let key, !key.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = Data(key.utf8)
        var status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Oh My Code AI (\(provider.title))"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

/// Keys kept only while the app runs (tests never touch the real Keychain).
@MainActor
final class InMemoryKeyStore: AIKeyStore {
    private var keys: [AIProviderKind: String] = [:]

    func key(for provider: AIProviderKind) -> String? { keys[provider] }

    func setKey(_ key: String?, for provider: AIProviderKind) throws {
        keys[provider] = key?.isEmpty == false ? key : nil
    }
}

/// Settings ▸ AI: the provider for inline suggestions and ⌘I edits, its models, and whether
/// suggestions show as you type. Keys are in the Keychain, never in the defaults.
@MainActor
@Observable
final class AISettings {
    /// Under tests: scratch defaults and keys in memory.
    static let shared = AppSettings.isRunningTests
        ? AISettings(defaults: ScratchDefaults.named("dev.zerovoid99.ohmycode.ai.tests"), keys: InMemoryKeyStore())
        : AISettings(defaults: .standard, keys: KeychainKeyStore())

    nonisolated static let suggestionMaxTokens = 256
    nonisolated static let editMaxTokens = 16_000
    nonisolated static let debounceRange = 100...2_000

    var provider: AIProviderKind { didSet { save() } }
    /// The OpenAI-compatible server's base URL (".../v1").
    var baseURL: String { didSet { save() } }
    /// Empty: the provider's default (the Claude API has defaults; other servers don't).
    var claudeSuggestionModel: String { didSet { save() } }
    var claudeEditModel: String { didSet { save() } }
    var openAISuggestionModel: String { didSet { save() } }
    var openAIEditModel: String { didSet { save() } }
    /// Suggestions while typing (⌥\ asks for one either way).
    var inlineSuggestionsEnabled: Bool { didSet { save() } }
    /// How long typing has to pause before a suggestion is asked for.
    var debounceMilliseconds: Int { didSet { save() } }

    /// Requests running now (the status bar's spinner).
    private(set) var requestsInFlight = 0
    /// The last request's error (the status bar's warning); cleared by the next success.
    var lastError: String?

    /// Providers with a key saved. Remembered in the defaults so that showing whether there's
    /// a key doesn't read the Keychain; the key itself is read when it's first needed.
    private(set) var savedKeys: Set<AIProviderKind>

    /// Tests: used instead of the configured provider.
    @ObservationIgnored var providerOverride: (any AIProvider)?
    /// The session requests go through (tests stub it).
    @ObservationIgnored var session: URLSession = .shared

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keys: AIKeyStore
    @ObservationIgnored private var keyCache: [AIProviderKind: String] = [:]
    @ObservationIgnored private var isLoading = false

    init(defaults: UserDefaults, keys: AIKeyStore) {
        self.defaults = defaults
        self.keys = keys
        isLoading = true
        provider = AIProviderKind(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .claude
        baseURL = defaults.string(forKey: Keys.baseURL) ?? OpenAICompatibleProvider.presets[0].baseURL
        claudeSuggestionModel = defaults.string(forKey: Keys.claudeSuggestionModel) ?? ""
        claudeEditModel = defaults.string(forKey: Keys.claudeEditModel) ?? ""
        openAISuggestionModel = defaults.string(forKey: Keys.openAISuggestionModel) ?? ""
        openAIEditModel = defaults.string(forKey: Keys.openAIEditModel) ?? ""
        inlineSuggestionsEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? false
        let debounce = defaults.object(forKey: Keys.debounce) as? Int ?? 350
        debounceMilliseconds = min(max(debounce, Self.debounceRange.lowerBound), Self.debounceRange.upperBound)
        savedKeys = Set((defaults.stringArray(forKey: Keys.savedKeys) ?? []).compactMap(AIProviderKind.init(rawValue:)))
        isLoading = false
    }

    private enum Keys {
        static let provider = "ai.provider"
        static let baseURL = "ai.baseURL"
        static let claudeSuggestionModel = "ai.claude.suggestionModel"
        static let claudeEditModel = "ai.claude.editModel"
        static let openAISuggestionModel = "ai.openAI.suggestionModel"
        static let openAIEditModel = "ai.openAI.editModel"
        static let enabled = "ai.inlineSuggestions"
        static let debounce = "ai.debounceMilliseconds"
        static let savedKeys = "ai.savedKeys"
    }

    private func save() {
        guard !isLoading else { return }
        defaults.set(provider.rawValue, forKey: Keys.provider)
        defaults.set(baseURL, forKey: Keys.baseURL)
        defaults.set(claudeSuggestionModel, forKey: Keys.claudeSuggestionModel)
        defaults.set(claudeEditModel, forKey: Keys.claudeEditModel)
        defaults.set(openAISuggestionModel, forKey: Keys.openAISuggestionModel)
        defaults.set(openAIEditModel, forKey: Keys.openAIEditModel)
        defaults.set(inlineSuggestionsEnabled, forKey: Keys.enabled)
        defaults.set(debounceMilliseconds, forKey: Keys.debounce)
        defaults.set(savedKeys.map(\.rawValue).sorted(), forKey: Keys.savedKeys)
    }

    // MARK: Models

    func suggestionModel(for provider: AIProviderKind) -> String {
        switch provider {
        case .claude: claudeSuggestionModel.trimmed.isEmpty ? ClaudeProvider.defaultSuggestionModel : claudeSuggestionModel.trimmed
        case .openAICompatible: openAISuggestionModel.trimmed
        }
    }

    func editModel(for provider: AIProviderKind) -> String {
        switch provider {
        case .claude: claudeEditModel.trimmed.isEmpty ? ClaudeProvider.defaultEditModel : claudeEditModel.trimmed
        // One model for both is common with a local server.
        case .openAICompatible: openAIEditModel.trimmed.isEmpty ? openAISuggestionModel.trimmed : openAIEditModel.trimmed
        }
    }

    var suggestionModel: String { suggestionModel(for: provider) }
    var editModel: String { editModel(for: provider) }

    // MARK: Keys

    func hasKey(for provider: AIProviderKind) -> Bool { savedKeys.contains(provider) }

    /// Saves the key for the current provider (empty removes it).
    func saveKey(_ key: String, for provider: AIProviderKind? = nil) throws {
        let provider = provider ?? self.provider
        let key = key.trimmed
        try keys.setKey(key, for: provider)
        keyCache[provider] = key.isEmpty ? nil : key
        if key.isEmpty { savedKeys.remove(provider) } else { savedKeys.insert(provider) }
        save()
    }

    func removeKey(for provider: AIProviderKind? = nil) throws {
        try saveKey("", for: provider)
    }

    private func apiKey(for provider: AIProviderKind) -> String? {
        if let cached = keyCache[provider] { return cached }
        guard hasKey(for: provider), let key = keys.key(for: provider), !key.isEmpty else { return nil }
        keyCache[provider] = key
        return key
    }

    // MARK: Providers

    /// What's missing before requests can be made (nil: nothing).
    var configurationProblem: String? {
        if providerOverride != nil { return nil }
        switch provider {
        case .claude:
            return hasKey(for: .claude) ? nil : "Add a Claude API key in Settings ▸ AI."
        case .openAICompatible:
            if OpenAICompatibleProvider.baseURL(from: baseURL) == nil { return "Set the server's base URL in Settings ▸ AI." }
            if openAISuggestionModel.trimmed.isEmpty { return "Set a model in Settings ▸ AI." }
            return nil
        }
    }

    var isConfigured: Bool { configurationProblem == nil }

    /// The provider requests go to.
    func makeProvider() throws -> any AIProvider {
        if let providerOverride { return providerOverride }
        if let problem = configurationProblem { throw AIError.notConfigured(problem) }
        switch provider {
        case .claude:
            guard let key = apiKey(for: .claude) else {
                throw AIError.notConfigured("The Claude API key couldn't be read from the Keychain. Add it again in Settings ▸ AI.")
            }
            return ClaudeProvider(apiKey: key, session: session)
        case .openAICompatible:
            guard let url = OpenAICompatibleProvider.baseURL(from: baseURL) else {
                throw AIError.notConfigured("Set the server's base URL in Settings ▸ AI.")
            }
            return OpenAICompatibleProvider(baseURL: url, apiKey: apiKey(for: .openAICompatible) ?? "", session: session)
        }
    }

    // MARK: Activity

    func requestStarted() { requestsInFlight += 1 }
    func requestEnded() { requestsInFlight = max(0, requestsInFlight - 1) }

    /// A tiny request, for Settings' Test button: the reply's first words, or the error.
    func test() async -> Result<String, Error> {
        do {
            let provider = try makeProvider()
            let request = AIRequest(purpose: .suggestion, model: suggestionModel, system: "Reply with the single word OK.",
                                    user: "Say OK.", maxTokens: 16)
            var reply = ""
            for try await piece in provider.stream(request) { reply += piece }
            return .success(reply.trimmed)
        } catch {
            return .failure(error)
        }
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
