import Foundation
import Testing
@testable import WakilKit

/// 3a-iii walk row 8: wakil-ctx answers each account call as an MCP result, its fields under
/// `structuredContent` — the shape the registry hands back — and the window reads them from there.
@Suite @MainActor struct WindowModelGitAccountsTests {
    private func window(answering replies: [String: [String: JSONValue]]) async -> WindowModel {
        let model = WindowModel.forTesting(scratchRoot: testScratchRoot)
        for (name, fields) in replies {
            await model.registryForTesting.register(Action(
                name: name, description: "stub", kind: .control, audience: .operatorOnly, schema: .object([:]),
                handler: { _ in
                    .object(["content": .array([.object(["type": .string("text"), "text": .string("{}")])]),
                             "structuredContent": .object(fields)])
                }))
        }
        return model
    }

    @Test func generatingAKeyAnswersThePublicKeyAndItsPath() async {
        let model = await window(answering: ["ctx_git_key_generate": [
            "publicKey": .string("ssh-ed25519 AAAA walk"), "path": .string("/o/git/ssh/github.com_ed25519")]])
        let r = await model.generateGitKey(host: "github.com", comment: "walk")
        #expect(r.publicKey == "ssh-ed25519 AAAA walk")
        #expect(r.path == "/o/git/ssh/github.com_ed25519")
        #expect(r.error == nil)
    }

    @Test func theListsAndTheTestReadTheirFields() async {
        let model = await window(answering: [
            "ctx_git_host_suggestions": ["hosts": .array([.object(["host": .string("github.com"), "repositories": .integer(3)])])],
            "ctx_git_ssh_keys": ["keys": .array([.object(["path": .string("/k/id"), "comment": .string("me"), "encrypted": .bool(true)])])],
            "ctx_git_account_test": ["user": .string("octo")],
            "ctx_git_gh_logins": ["logins": .array([.object(["host": .string("github.com"), "user": .string("octo")])])],
            "ctx_git_device_start": ["userCode": .string("AB-CD"), "verificationUri": .string("https://github.com/login/device"),
                                     "deviceCode": .string("dc"), "interval": .integer(5)],
        ])
        #expect(await model.gitHostSuggestions().map(\.host) == ["github.com"])
        #expect(await model.gitSSHKeys().map(\.path) == ["/k/id"])
        #expect(await model.testGitAccount(host: "github.com").user == "octo")
        #expect(await model.gitGhLogins().map(\.user) == ["octo"])
        #expect(await model.gitDeviceStart(provider: .github).userCode == "AB-CD")
    }

    @Test func devicePollPassesAPIAccess() async {
        let model = WindowModel.forTesting(scratchRoot: testScratchRoot)
        let seen = ParamsBox()
        await model.registryForTesting.register(Action(
            name: "ctx_git_device_poll", description: "stub", kind: .control, audience: .operatorOnly, schema: .object([:]),
            handler: { params in
                await seen.add(params)
                return .object(["structuredContent": .object(["pending": .bool(true)])])
            }))
        _ = await model.gitDevicePoll(provider: .github, host: "github.com", deviceCode: "dc", apiAccess: true)
        _ = await model.gitDevicePoll(provider: .github, host: "github.com", deviceCode: "dc")
        let calls = await seen.all
        #expect(calls.count == 2)
        guard case .object(let first) = calls[0], case .object(let second) = calls[1] else { return }
        #expect(first["apiAccess"] == .bool(true))
        #expect(second["apiAccess"] == nil)
    }

    @Test func theAPIAccessCallsGoToTheirActions() async {
        let model = await window(answering: [
            "ctx_git_api_access_token_set": [:], "ctx_git_api_access_remove": [:],
            "ctx_git_api_access_test": ["user": .string("octo")],
        ])
        #expect(await model.setGitAPIAccessToken(host: "github.com", token: "t") == nil)
        #expect(await model.testGitAPIAccess(host: "github.com").user == "octo")
        #expect(await model.removeGitAPIAccess(host: "github.com") == nil)
    }
}

private actor ParamsBox {
    private(set) var all: [JSONValue] = []
    func add(_ p: JSONValue) { all.append(p) }
}
