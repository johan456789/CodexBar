import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIConfigTokenAccountRemovalTests {
    @Test
    func `account selection matches usage flags and rejects conflicts`() throws {
        #expect(try Self.select(label: nil, index: nil) == nil)
        #expect(try Self.select(label: " work ", index: nil) == .label("work"))
        #expect(try Self.select(label: nil, index: "2") == .index(1))
        for (label, index, fields) in [
            ("work", "1", false),
            (nil, "0", false),
            (nil, "x", false),
            ("work", nil, true),
        ] as [(String?, String?, Bool)] {
            #expect(throws: CLIArgumentError.self) {
                _ = try Self.select(label: label, index: index, clearsCredentialFields: fields)
            }
        }
    }

    @Test
    func `removing accounts follows Settings active account rules`() throws {
        let config = Self.config(labels: ["a", "b", "c"], active: 1)

        let (keptActive, removedFirst) = try CodexBarCLI.configRemovingTokenAccount(
            config,
            provider: .deepseek,
            selection: .label("A"))
        #expect(removedFirst.label == "a")
        #expect(Self.labels(keptActive) == ["b", "c"])
        #expect(keptActive.providerConfig(for: .deepseek)?.tokenAccounts?.activeIndex == 0)

        let (movedActive, removedActive) = try CodexBarCLI.configRemovingTokenAccount(
            config,
            provider: .deepseek,
            selection: .index(1))
        #expect(removedActive.label == "b")
        #expect(Self.labels(movedActive) == ["a", "c"])
        #expect(movedActive.providerConfig(for: .deepseek)?.tokenAccounts?.activeIndex == 1)

        let single = Self.config(labels: ["only"], active: 0)
        let (empty, _) = try CodexBarCLI.configRemovingTokenAccount(single, provider: .deepseek, selection: .index(0))
        let entry = try #require(empty.providerConfig(for: .deepseek))
        #expect(entry.tokenAccounts == nil)
        #expect(entry.enabled == true)
        #expect(entry.apiKey == "legacy-key")
    }

    @Test
    func `removal refuses missing ambiguous and unsupported accounts`() {
        let duplicates = Self.config(labels: ["work", "Work"], active: 0)
        #expect(throws: CLIArgumentError.self) {
            _ = try CodexBarCLI.configRemovingTokenAccount(duplicates, provider: .deepseek, selection: .label("work"))
        }
        #expect(throws: TokenAccountCLIError.self) {
            _ = try CodexBarCLI.configRemovingTokenAccount(duplicates, provider: .deepseek, selection: .label("none"))
        }
        #expect(throws: TokenAccountCLIError.self) {
            _ = try CodexBarCLI.configRemovingTokenAccount(duplicates, provider: .deepseek, selection: .index(2))
        }
        #expect(throws: TokenAccountCLIError.self) {
            _ = try CodexBarCLI.configRemovingTokenAccount(
                CodexBarConfig.makeDefault(),
                provider: .deepseek,
                selection: .index(0))
        }
        #expect(throws: CLIArgumentError.self) {
            _ = try CodexBarCLI.configRemovingTokenAccount(duplicates, provider: .antigravity, selection: .index(0))
        }
    }

    @Test
    func `real CLI removes a token account and leaves the file alone on errors`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("config-remove-account-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        let store = CodexBarConfigStore(fileURL: url)
        try store.save(Self.config(labels: ["personal", "work", "work"], active: 0))

        let before = try Data(contentsOf: url)
        do {
            _ = try await Self.run(root: root, arguments: ["--provider", "deepseek", "--account", "work"])
            Issue.record("Ambiguous label unexpectedly succeeded")
        } catch let SubprocessRunnerError.nonZeroExit(code, stderr) {
            #expect(code == 1)
            #expect(stderr.contains("2 token accounts are labeled 'work' for deepseek (indexes 2, 3)"))
        }
        #expect(try Data(contentsOf: url) == before)

        let output = try await Self.run(
            root: root,
            arguments: ["--provider", "deepseek", "--account-index", "3", "--json"])
        let json = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(Set(json.keys) == ["provider", "cleared", "tokenAccount", "configPath"])
        #expect(json["cleared"] as? [String] == ["tokenAccount"])
        #expect(json["tokenAccount"] as? String == "work")
        #expect(!output.contains("fixture-token"))

        let text = try await Self.run(root: root, arguments: ["--provider", "deepseek", "--account", "PERSONAL"])
        #expect(text == "Config: removed token account \"personal\" for DeepSeek\n")
        let entry = try #require(try store.load()?.providerConfig(for: .deepseek))
        #expect(entry.tokenAccounts?.accounts.map(\.label) == ["work"])
        #expect(entry.tokenAccounts?.activeIndex == 0)
        #expect(entry.apiKey == "legacy-key")
    }

    private static func select(
        label: String?,
        index: String?,
        clearsCredentialFields: Bool = false) throws -> ConfigTokenAccountSelection?
    {
        try CodexBarCLI.configTokenAccountSelection(
            label: label,
            index: index,
            clearsCredentialFields: clearsCredentialFields)
    }

    private static func config(labels: [String], active: Int) -> CodexBarConfig {
        var config = CodexBarConfig.makeDefault()
        let accounts = labels.enumerated().map { offset, label in
            ProviderTokenAccount(
                id: UUID(),
                label: label,
                token: "fixture-token-\(offset)",
                addedAt: 1000,
                lastUsed: nil)
        }
        config.setProviderConfig(ProviderConfig(
            id: .deepseek,
            enabled: true,
            apiKey: "legacy-key",
            tokenAccounts: ProviderTokenAccountData(version: 1, accounts: accounts, activeIndex: active)))
        return config
    }

    private static func labels(_ config: CodexBarConfig) -> [String] {
        config.providerConfig(for: .deepseek)?.tokenAccounts?.accounts.map(\.label) ?? []
    }

    private static func run(root: URL, arguments: [String]) async throws -> String {
        let result = try await SubprocessRunner.run(
            binary: TestBuildProducts.executableURL(named: "CodexBarCLI").path,
            arguments: ["config", "clear-credential"] + arguments,
            environment: [
                "CODEXBAR_CONFIG": root.appendingPathComponent("config.json").path,
                "HOME": root.path,
                "CFFIXED_USER_HOME": root.path,
                "CODEX_HOME": root.appendingPathComponent(".codex").path,
                "CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS": "1",
            ],
            timeout: 15,
            label: "synthetic config remove token account")
        return result.stdout
    }
}
