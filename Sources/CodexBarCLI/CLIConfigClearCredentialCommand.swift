import CodexBarCore
import Commander
import Foundation

enum ConfigCredentialField: String, Encodable {
    case apiKey
    case cookieHeader
    case tokenAccount
}

/// Token account picked by `--account <label>` or `--account-index <n>`; the index is zero-based.
enum ConfigTokenAccountSelection: Equatable {
    case label(String)
    case index(Int)
}

extension CodexBarCLI {
    static func runConfigClearCredential(_ values: ParsedValues) {
        let output = CLIOutputPreferences.from(values: values)
        guard let rawProvider = values.options["provider"]?.last,
              let provider = ProviderDescriptorRegistry.cliNameMap[rawProvider.lowercased()]
        else {
            Self.exit(
                code: .failure,
                message: "Unknown or missing provider. Use --provider <name>.",
                output: output,
                kind: .args)
        }
        let clearsAPIKey = values.flags.contains("apiKey")
        let clearsCookie = values.flags.contains("cookie")
        let selection: ConfigTokenAccountSelection?
        do {
            selection = try Self.configTokenAccountSelection(
                label: values.options["account"]?.last,
                index: values.options["accountIndex"]?.last,
                clearsCredentialFields: clearsAPIKey || clearsCookie)
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .args)
        }
        if let selection {
            Self.runConfigRemoveTokenAccount(provider: provider, selection: selection, output: output)
        }
        let fields = Self.configCredentialFields(apiKey: clearsAPIKey, cookie: clearsCookie)

        let store = CodexBarConfigStore()
        let (config, cleared) = Self.configClearingCredential(
            Self.loadConfig(output: output),
            provider: provider,
            fields: fields)
        // Nothing stored means nothing to write; a missing config file stays missing.
        if !cleared.isEmpty {
            do {
                try store.save(config)
            } catch {
                Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .config)
            }
        }

        let result = ConfigClearCredentialResult(
            provider: provider.rawValue,
            cleared: cleared,
            tokenAccount: nil,
            configPath: store.fileURL.path)
        switch output.format {
        case .text:
            let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
            if cleared.isEmpty {
                print("Config: no stored \(Self.configCredentialDescription(fields, joiner: "or")) for \(name)")
            } else {
                print("Config: cleared \(Self.configCredentialDescription(cleared, joiner: "and")) for \(name)")
            }
        case .json:
            Self.printJSON(result, pretty: output.pretty)
        }
        Self.exit(code: .success, output: output, kind: .config)
    }

    /// Clears both credentials unless a flag narrows the command to one of them.
    static func configCredentialFields(apiKey: Bool, cookie: Bool) -> [ConfigCredentialField] {
        let both: [ConfigCredentialField] = [.apiKey, .cookieHeader]
        guard apiKey || cookie else { return both }
        return both.filter { $0 == .apiKey ? apiKey : cookie }
    }

    private static func runConfigRemoveTokenAccount(
        provider: UsageProvider,
        selection: ConfigTokenAccountSelection,
        output: CLIOutputPreferences) -> Never
    {
        let store = CodexBarConfigStore()
        let config: CodexBarConfig
        let removed: ProviderTokenAccount
        do {
            (config, removed) = try Self.configRemovingTokenAccount(
                Self.loadConfig(output: output),
                provider: provider,
                selection: selection)
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .args)
        }
        do {
            try store.save(config)
        } catch {
            Self.exit(code: .failure, message: error.localizedDescription, output: output, kind: .config)
        }

        let result = ConfigClearCredentialResult(
            provider: provider.rawValue,
            cleared: [.tokenAccount],
            tokenAccount: removed.label,
            configPath: store.fileURL.path)
        switch output.format {
        case .text:
            let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
            print("Config: removed token account \"\(removed.label)\" for \(name)")
        case .json:
            Self.printJSON(result, pretty: output.pretty)
        }
        Self.exit(code: .success, output: output, kind: .config)
    }

    /// `--account`/`--account-index` match `usage`, but an ambiguous label is refused instead of using the first match.
    static func configTokenAccountSelection(
        label rawLabel: String?,
        index rawIndex: String?,
        clearsCredentialFields: Bool) throws -> ConfigTokenAccountSelection?
    {
        let label = SettingsValue.cleaned(rawLabel)
        guard label != nil || rawIndex != nil else { return nil }
        guard label == nil || rawIndex == nil else {
            throw CLIArgumentError("Use either --account or --account-index, not both.")
        }
        guard !clearsCredentialFields else {
            throw CLIArgumentError("--account and --account-index cannot be combined with --api-key or --cookie.")
        }
        if let label { return .label(label) }
        guard let rawIndex, let index = Int(rawIndex), index > 0 else {
            throw CLIArgumentError("--account-index must be a positive integer.")
        }
        return .index(index - 1)
    }

    static func configRemovingTokenAccount(
        _ config: CodexBarConfig,
        provider: UsageProvider,
        selection: ConfigTokenAccountSelection) throws -> (config: CodexBarConfig, removed: ProviderTokenAccount)
    {
        // Provider-specific by design: Settings also clears Antigravity's shared OAuth cache when removing accounts.
        guard provider != .antigravity else {
            throw CLIArgumentError(
                "Remove Antigravity accounts in Settings, which also clears their shared OAuth cache.")
        }
        var updated = config.normalized()
        guard var providerConfig = updated.providerConfig(for: provider.instanceID),
              let data = providerConfig.tokenAccounts, !data.accounts.isEmpty
        else { throw TokenAccountCLIError.noAccounts(provider) }

        let removedIndex: Int
        switch selection {
        case let .label(label):
            let matches = data.accounts.indices.filter { data.accounts[$0].label.lowercased() == label.lowercased() }
            guard let first = matches.first else { throw TokenAccountCLIError.accountNotFound(provider, label) }
            guard matches.count == 1 else {
                let indexes = matches.map { "\($0 + 1)" }.joined(separator: ", ")
                throw CLIArgumentError(
                    "\(matches.count) token accounts are labeled '\(label)' for \(provider.rawValue) "
                        + "(indexes \(indexes)); use --account-index.")
            }
            removedIndex = first
        case let .index(index):
            guard data.accounts.indices.contains(index) else {
                throw TokenAccountCLIError.indexOutOfRange(provider, index + 1, data.accounts.count)
            }
            removedIndex = index
        }

        // Same active-account rules as removing an account in Settings.
        let activeID = data.accounts[data.clampedActiveIndex()].id
        let removed = data.accounts[removedIndex]
        var remaining = data.accounts
        remaining.remove(at: removedIndex)
        if remaining.isEmpty {
            providerConfig.tokenAccounts = nil
        } else {
            let activeIndex = remaining.firstIndex { $0.id == activeID } ?? min(removedIndex, remaining.count - 1)
            providerConfig.tokenAccounts = ProviderTokenAccountData(
                version: data.version,
                accounts: remaining,
                activeIndex: activeIndex)
        }
        if TokenAccountSupportCatalog.support(for: provider)?.clearsAPIKeyOnMutation == true {
            providerConfig.apiKey = nil
        }
        updated.setProviderConfig(providerConfig)
        return (updated, removed)
    }

    static func configClearingCredential(
        _ config: CodexBarConfig,
        provider: UsageProvider,
        fields: [ConfigCredentialField]) -> (config: CodexBarConfig, cleared: [ConfigCredentialField])
    {
        var updated = config.normalized()
        guard var providerConfig = updated.providerConfig(for: provider.instanceID) else { return (updated, []) }
        var cleared: [ConfigCredentialField] = []
        if fields.contains(.apiKey), providerConfig.apiKey != nil {
            providerConfig.apiKey = nil
            // Provider-specific by design: Settings drops Moonshot's key-bound region together with the key.
            if provider == .moonshot {
                providerConfig.apiKeyRegion = nil
            }
            cleared.append(.apiKey)
        }
        if fields.contains(.cookieHeader), providerConfig.cookieHeader != nil {
            providerConfig.cookieHeader = nil
            cleared.append(.cookieHeader)
        }
        guard !cleared.isEmpty else { return (updated, []) }
        updated.setProviderConfig(providerConfig)
        return (updated, cleared)
    }

    private static func configCredentialDescription(_ fields: [ConfigCredentialField], joiner: String) -> String {
        fields.map { field in
            switch field {
            case .apiKey: "API key"
            case .cookieHeader: "manual cookie"
            case .tokenAccount: "token account"
            }
        }.joined(separator: " \(joiner) ")
    }
}

struct ConfigClearCredentialOptions: CommanderParsable {
    @OptionGroup
    var common: CLICommonOptions

    @Option(name: .long("provider"), help: ProviderHelp.concreteOptionHelp)
    var provider: String?

    @Flag(name: .long("api-key"), help: "Clear only the stored API key")
    var apiKey: Bool = false

    @Flag(name: .long("cookie"), help: "Clear only the stored manual cookie")
    var cookie: Bool = false

    @Option(name: .long("account"), help: "Remove the token account with this label")
    var account: String?

    @Option(name: .long("account-index"), help: "Remove the token account at this index (1-based)")
    var accountIndex: String?
}

private struct ConfigClearCredentialResult: Encodable {
    let provider: String
    let cleared: [ConfigCredentialField]
    /// Label of the removed token account; omitted when clearing provider-level credentials.
    let tokenAccount: String?
    let configPath: String
}
