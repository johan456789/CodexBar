import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIConfigAPIKeyTokenAccountTests {
    @Test
    func `token account API keys follow provider descriptors`() {
        #expect(CodexBarCLI.storesAPIKeyAsTokenAccount(.deepseek))
        // OAuth and session token accounts are not API keys, and provider-level keys keep their existing path.
        for provider in [UsageProvider.antigravity, .grok, .zai, .elevenlabs, .openrouter] {
            #expect(!CodexBarCLI.storesAPIKeyAsTokenAccount(provider))
        }
        for provider in UsageProvider.allCases where CodexBarCLI.storesAPIKeyAsTokenAccount(provider) {
            let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
            #expect(!ProviderConfigEnvironment.supportsAPIKeyOverride(for: provider))
            #expect(descriptor.fetchPlan.sourceModes.contains(.api))
            #expect(TokenAccountSupportCatalog.support(for: provider) != nil)
        }
    }

    @Test
    func `token account providers accept only a label`() throws {
        let labeled = try Self.resolve(.deepseek, label: " work ")
        #expect(labeled == ConfigAPIKeyAccountOptions(label: "work"))
        let unlabeled = try Self.resolve(.deepseek)
        #expect(unlabeled == ConfigAPIKeyAccountOptions(label: nil))
        #expect(throws: CLIArgumentError.self) {
            _ = try Self.resolve(.deepseek, usageScope: "team")
        }
        #expect(throws: CLIArgumentError.self) {
            _ = try Self.resolve(.elevenlabs, label: "work")
        }
    }

    @Test
    func `token account keys append and activate like Settings`() throws {
        var config = CodexBarConfig.makeDefault()
        config.setProviderConfig(ProviderConfig(id: .deepseek, enabled: false, apiKey: "legacy-key"))
        config = Self.store(config, "sk-first", label: nil, enable: false)
        config = Self.store(config, "sk-second", label: "work", enable: true)
        // Settings appends duplicate tokens too; the CLI does not dedupe.
        config = Self.store(config, "sk-second", label: "work", enable: true)

        let entry = try #require(config.providerConfig(for: .deepseek))
        let accounts = try #require(entry.tokenAccounts?.accounts)
        #expect(accounts.map(\.label) == ["Account 1", "work", "work"])
        #expect(accounts.map(\.token) == ["sk-first", "sk-second", "sk-second"])
        #expect(accounts.allSatisfy { $0.usageScope == nil && $0.organizationID == nil && $0.workspaceID == nil })
        #expect(entry.tokenAccounts?.activeIndex == 2)
        #expect(entry.enabled == true)
        #expect(entry.apiKey == "legacy-key")
    }

    @Test
    func `real CLI stores DeepSeek key as a token account without echoing it`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("config-token-key-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        let store = CodexBarConfigStore(fileURL: url)

        let output = try await Self.run(
            root: root,
            arguments: ["--provider", "deepseek", "--stdin", "--label", "work", "--json"],
            stdin: "sk-fixture-secret\n")
        let json = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(Set(json.keys) == ["provider", "enabled", "tokenAccount", "configPath"])
        #expect(json["tokenAccount"] as? String == "work")
        #expect(json["enabled"] as? Bool == true)
        #expect(!output.contains("sk-fixture-secret"))
        let account = try #require(try store.load()?.providerConfig(for: .deepseek)?.tokenAccounts?.accounts.first)
        #expect(account.label == "work")
        #expect(account.token == "sk-fixture-secret")

        let text = try await Self.run(root: root, arguments: ["--provider", "deepseek", "--api-key", "sk-next"])
        #expect(text == "Config: stored API key as token account \"Account 2\" for DeepSeek and enabled\n")

        let before = try Data(contentsOf: url)
        do {
            _ = try await Self.run(root: root, arguments: ["--provider", "grok", "--api-key", "fixture"])
            Issue.record("Grok unexpectedly accepted an API key")
        } catch let SubprocessRunnerError.nonZeroExit(code, stderr) {
            #expect(code == 1)
            #expect(stderr.contains("grok does not support config API keys"))
        }
        #expect(try Data(contentsOf: url) == before)
    }

    private static func resolve(
        _ provider: UsageProvider,
        label: String? = nil,
        usageScope: String? = nil) throws -> ConfigAPIKeyAccountOptions?
    {
        try CodexBarCLI.resolveConfigAPIKeyAccountOptions(
            provider: provider,
            label: label,
            usageScope: usageScope,
            organizationID: nil,
            workspaceID: nil)
    }

    private static func store(_ config: CodexBarConfig, _ key: String, label: String?, enable: Bool) -> CodexBarConfig {
        CodexBarCLI.configSettingAPIKey(
            config,
            provider: .deepseek,
            apiKey: key,
            enableProvider: enable,
            accountOptions: ConfigAPIKeyAccountOptions(label: label))
    }

    private static func run(root: URL, arguments: [String], stdin: String = "") async throws -> String {
        let input = root.appendingPathComponent("stdin-\(UUID())")
        try Data(stdin.utf8).write(to: input)
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        let result = try await SubprocessRunner.run(
            binary: TestBuildProducts.executableURL(named: "CodexBarCLI").path,
            arguments: ["config", "set-api-key"] + arguments,
            environment: [
                "CODEXBAR_CONFIG": root.appendingPathComponent("config.json").path,
                "HOME": root.path,
                "CFFIXED_USER_HOME": root.path,
                "CODEX_HOME": root.appendingPathComponent(".codex").path,
                "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
            ],
            timeout: 15,
            standardInput: handle,
            label: "synthetic config set api key token account")
        return result.stdout
    }
}
