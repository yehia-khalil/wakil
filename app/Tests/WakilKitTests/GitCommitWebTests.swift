import Foundation
import Testing
@testable import WakilKit

/// 3c-i: the blame hover's Open on GitHub (GitLab, Bitbucket) — the remote mapped to the commit's page,
/// and `editor_blame` offering it only for a pushed commit of a root whose origin has one.
@Suite struct GitCommitWebTests {
    private let sha = "0123456789abcdef0123456789abcdef01234567"

    @Test func eachHostAndEachRemoteFormMapsToTheCommitPage() {
        let cases: [(String, String, String)] = [
            ("git@github.com:acme/app.git", "GitHub", "https://github.com/acme/app/commit/\(sha)"),
            ("ssh://git@github.com/acme/app.git", "GitHub", "https://github.com/acme/app/commit/\(sha)"),
            ("ssh://git@github.com:22/acme/app", "GitHub", "https://github.com/acme/app/commit/\(sha)"),
            ("https://github.com/acme/app.git", "GitHub", "https://github.com/acme/app/commit/\(sha)"),
            ("https://github.com/acme/app/", "GitHub", "https://github.com/acme/app/commit/\(sha)"),
            ("git@gitlab.com:group/sub/deeper/app.git", "GitLab", "https://gitlab.com/group/sub/deeper/app/-/commit/\(sha)"),
            ("ssh://git@gitlab.com/group/app.git", "GitLab", "https://gitlab.com/group/app/-/commit/\(sha)"),
            ("https://gitlab.com/group/sub/app.git", "GitLab", "https://gitlab.com/group/sub/app/-/commit/\(sha)"),
            ("git@bitbucket.org:team/app.git", "Bitbucket", "https://bitbucket.org/team/app/commits/\(sha)"),
            ("ssh://git@bitbucket.org/team/app.git", "Bitbucket", "https://bitbucket.org/team/app/commits/\(sha)"),
            ("https://bitbucket.org/team/app", "Bitbucket", "https://bitbucket.org/team/app/commits/\(sha)"),
            ("  git@GitHub.com:acme/app.git\n", "GitHub", "https://github.com/acme/app/commit/\(sha)"),
        ]
        for (remote, host, url) in cases {
            #expect(gitCommitWebPage(remote: remote, commit: sha) == GitCommitWebPage(host: host, url: url), "\(remote)")
        }
    }

    @Test func credentialsAndDotGitAreStripped() {
        #expect(gitCommitWebPage(remote: "https://x-access-token:ghp_secret@github.com/acme/app.git", commit: sha)?.url
                == "https://github.com/acme/app/commit/\(sha)")
        #expect(gitCommitWebPage(remote: "https://oauth2:glpat@gitlab.com/g/s/app.git", commit: sha)?.url
                == "https://gitlab.com/g/s/app/-/commit/\(sha)")
        #expect(gitCommitWebPage(remote: "ssh://git:pw@bitbucket.org/team/app.git", commit: sha)?.url
                == "https://bitbucket.org/team/app/commits/\(sha)")
        let page = gitCommitWebPage(remote: "https://ada:tok@github.com/acme/app.git", commit: sha)
        #expect(page.map { !$0.url.contains("tok") && !$0.url.contains("ada") && !$0.url.hasSuffix(".git") } == true)
    }

    @Test func anyOtherHostOrFormHasNoPage() {
        for remote in ["git@gitlab.example.com:g/app.git", "https://github.example.com/acme/app", "github-work:acme/app.git",
                       "file:///srv/app.git", "/srv/app.git", "", "https://github.com/acme", "https://github.com/acme/app/extra",
                       "git@bitbucket.org:team", "http://github.com/acme/app", "git://github.com/acme/app.git",
                       "https://gitlab.com/solo", "https://github.com/acme/../app"] {
            #expect(gitCommitWebPage(remote: remote, commit: sha) == nil, "\(remote)")
        }
        #expect(gitCommitWebPage(remote: "git@github.com:acme/app.git", commit: String(repeating: "0", count: 40)) == nil)
        #expect(gitCommitWebPage(remote: "git@github.com:acme/app.git", commit: "not-a-sha") == nil)
    }

    @Test func theHoverOffersThePageOnlyWhenThereIsOne() {
        var b = GitBlameInfo(line: 1, id: sha, author: "Ada", date: "2026-10-01T00:00:00Z", subject: "Seed")
        #expect(!(editorBlameHover(b) ?? "").contains("wakil.blame.web"))
        b.web = GitCommitWebPage(host: "GitLab", url: "https://gitlab.com/g/app/-/commit/\(sha)")
        #expect((editorBlameHover(b) ?? "").hasSuffix(
            "[Open Changes](command:wakil.blame.open) · [Copy Commit ID](command:wakil.blame.copy) · [Open on GitLab](command:wakil.blame.web)"))
    }

    @Test func editorBlameSetsThePageForPushedLinesAndReadsTheOriginOncePerRoot() async throws {
        let git = BlameWebGit(origin: "git@github.com:acme/app.git")
        let registry = try await blameRegistry(git)
        func blame() async throws -> [GitBlameInfo] {
            let reply = try await registry.dispatch(name: "editor_blame", params: .object(["root": .string("/p"), "path": .string("a.txt")]),
                                                    origin: .ui, caller: .test("staging"), confirmation: nil)
            guard case .object(let o) = reply, let lines = o["lines"] else { return [] }
            return try JSONDecoder().decode([GitBlameInfo].self, from: JSONEncoder().encode(lines))
        }
        let first = try await blame()
        #expect(first.map(\.web?.url) == ["https://github.com/acme/app/commit/\(sha)", nil, nil])
        #expect(first[0].web?.host == "GitHub")
        _ = try await blame()
        #expect(await git.calls == ["git_origin", "git_blame:pushed", "git_blame:pushed"])
    }

    @Test func editorBlameAsksNothingMoreForARootWithNoPage() async throws {
        let git = BlameWebGit(origin: "git@gitlab.example.com:g/app.git")
        let registry = try await blameRegistry(git)
        let reply = try await registry.dispatch(name: "editor_blame", params: .object(["root": .string("/p"), "path": .string("a.txt")]),
                                                origin: .ui, caller: .test("staging"), confirmation: nil)
        guard case .object(let o) = reply, case .array(let lines)? = o["lines"] else { Issue.record("no lines"); return }
        #expect(lines.allSatisfy { if case .object(let l) = $0 { l["web"] == nil } else { false } })
        #expect(await git.calls == ["git_origin", "git_blame"])
    }

    private func blameRegistry(_ git: BlameWebGit) async throws -> ActionRegistry {
        let dir = testScratchRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let registry = ActionRegistry(journalDirectory: dir, sessionId: "t")
        await registerEditorActions(into: registry, panes: PaneStore(kinds: PaneKinds.standard), layout: LayoutStore(),
                                    files: nil, fileLists: nil, gitStatus: GitStatus(git: git, roots: { ["/p"] }),
                                    roots: { ["/p"] })
        return registry
    }
}

/// A wakil-git answering `git_origin` and `git_blame`: line 1 pushed, line 2 committed here only,
/// line 3 not committed. It records each call, and whether blame was asked to mark pushed lines.
private actor BlameWebGit: ToolCaller {
    let origin: String
    var calls: [String] = []
    init(origin: String) { self.origin = origin }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        func ok(_ o: [String: JSONValue]) -> JSONValue { .object(["structuredContent": .object(o)]) }
        switch name {
        case "git_origin":
            calls.append(name)
            return ok(["url": .string(origin)])
        case "git_blame":
            let pushed: Bool = if case .object(let a) = arguments, a["pushed"] == .bool(true) { true } else { false }
            calls.append(pushed ? "git_blame:pushed" : "git_blame")
            func line(_ n: Int, _ id: String, _ isPushed: Bool) -> JSONValue {
                var l: [String: JSONValue] = ["line": .integer(Int64(n)), "id": .string(id), "author": .string("Ada"),
                                              "date": .string("2026-10-01T00:00:00Z"), "subject": .string("s")]
                if pushed && isPushed { l["pushed"] = .bool(true) }
                return .object(l)
            }
            return ok(["lines": .array([line(1, "0123456789abcdef0123456789abcdef01234567", true),
                                        line(2, String(repeating: "b", count: 40), false),
                                        line(3, String(repeating: "0", count: 40), false)])])
        default:
            return ok([:])
        }
    }
}
