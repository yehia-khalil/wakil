import Foundation
import Testing
@testable import WakilKit

/// A wakil-git that answers fetch (or fails it) and can park a push.
private actor FetchGit: ToolCaller {
    var calls: [String] = []
    var failFetch: String?
    var gatePush = false
    var hangNextFetch = false
    var fetchCancelled = false
    func hangFetch() { hangNextFetch = true }
    private var parked: CheckedContinuation<Void, Never>?
    func fail(_ text: String?) { failFetch = text }
    func gate() { gatePush = true }
    func release() { gatePush = false; parked?.resume(); parked = nil }
    func parkedNow() -> Bool { parked != nil }
    private func park(_ c: CheckedContinuation<Void, Never>) { if gatePush { parked = c } else { c.resume() } }
    func count(_ name: String) -> Int { calls.filter { $0 == name }.count }

    func callTool(name: String, arguments: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        func ok(_ o: [String: JSONValue]) -> JSONValue { .object(["structuredContent": .object(o)]) }
        func err(_ t: String) -> JSONValue {
            .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string(t)])])])
        }
        if name != "git_status" { calls.append(name) }
        switch name {
        case "git_status":
            return ok(["root": .string("/p"), "branch": .string("main"), "detached": .string(""), "upstream": .string("origin/main"),
                       "ahead": .integer(1), "behind": .integer(0), "files": .array([])])
        case "git_fetch":
            if hangNextFetch {
                hangNextFetch = false
                // A host that never answers: only cancelling the call ends it.
                do { try await Task.sleep(for: .seconds(3600)) } catch { fetchCancelled = true; throw error }
            }
            if let failFetch { return err(failFetch) }
            return ok(["summary": .string(""), "ahead": .integer(1), "behind": .integer(0)])
        case "git_push":
            await withCheckedContinuation { c in Task { await self.park(c) } }
            return err("Rejected: the remote has newer commits. Pull or Sync first")
        default: return ok([:])
        }
    }
}

@MainActor
private func fetchWindow() async -> (WindowModel, FetchGit) {
    let git = FetchGit()
    let status = GitStatus(git: git, roots: { ["/p"] })
    await status.refresh()
    let window = WindowModel.forTesting(scratchRoot: testScratchRoot, gitStatus: status)
    await registerEditorChangesWrites(into: window.registryForTesting, gitStatus: status, panes: PaneStore(kinds: PaneKinds.standard),
                                      layout: LayoutStore(), writes: GitWriteFlights())
    await window.refreshPanes()
    return (window, git)
}

@Suite @MainActor struct WindowModelBackgroundFetchTests {
    @Test func theIntervalIsFiveMinutes() async {
        let (window, _) = await fetchWindow()
        #expect(window.backgroundFetchInterval == .seconds(300))
    }

    @Test func fetchesEachRootOnTheIntervalWhileAnEditorPaneIsOpen() async {
        let (window, git) = await fetchWindow()
        var slept: [Duration] = []
        window.backgroundFetchSleep = { d in
            slept.append(d)
            if slept.count > 1 { try await Task.sleep(for: .seconds(3600)) }
        }
        #expect(await window.openPane(kind: "editor"))
        await window.refreshLayout()
        window.updateBackgroundFetch()
        for _ in 0..<200 where await git.count("git_fetch") == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(await git.count("git_fetch") == 1)
        #expect(slept.first == .seconds(300))
        window.stopBackgroundFetch()
    }

    @Test func noFetchWithoutAnEditorPaneOrWhileTheAppIsInactive() async {
        let (window, git) = await fetchWindow()
        window.backgroundFetchSleep = { (_: Duration) in try await Task.sleep(for: .seconds(3600)) }
        window.updateBackgroundFetch()
        #expect(window.backgroundFetchRunning == false)
        window.setAppActive(false)
        #expect(await window.openPane(kind: "editor"))
        await window.refreshLayout()
        #expect(window.backgroundFetchRunning == false)
        window.setAppActive(true)
        #expect(window.backgroundFetchRunning)
        window.stopBackgroundFetch()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await git.count("git_fetch") == 0)
    }

    @Test func aFailedFetchIsAHeaderNoteNotAnError() async {
        let (window, git) = await fetchWindow()
        await git.fail("Authentication failed for dev-initech on github.com — Settings → Organisation → Git")
        await window.backgroundFetchOnce()
        #expect(window.changesRemoteNotes["/p"]?.contains("Authentication failed for dev-initech on github.com — Settings → Organisation → Git") == true)
        #expect(window.changesErrors["/p"] == nil)
        await git.fail(nil)
        await window.backgroundFetchOnce()
        #expect(window.changesRemoteNotes["/p"] == nil)
    }

    @Test func aPushThatLandsAfterAnOrgSwitchIsNotShown() async throws {
        let (window, git) = await fetchWindow()
        await git.gate()
        let push = Task { await window.changesRemote(root: "/p", .push) }
        while await !git.parkedNow() { try await Task.sleep(for: .milliseconds(1)) }
        await window.invalidateForOrgChange()
        await git.release()
        await push.value
        #expect(window.changesErrors["/p"] == nil)
    }

    // Review I5: a background fetch stuck on a host that never answers must not refuse the
    // operator's own write on that root — the write cancels it and runs.
    @Test func anOperatorWriteCancelsAHungBackgroundFetch() async {
        let (window, git) = await fetchWindow()
        await git.hangFetch()
        let background = Task { await window.backgroundFetchOnce() }
        for _ in 0..<200 where await git.count("git_fetch") == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        await window.changesFetch(root: "/p")
        #expect(window.changesErrors["/p"] == nil)
        #expect(await git.fetchCancelled)
        #expect(await git.count("git_fetch") == 2)
        await background.value
    }

    @Test func aBackgroundFetchGivesUpAfterItsDeadline() async {
        let (window, git) = await fetchWindow()
        window.backgroundFetchTimeout = .milliseconds(100)
        await git.hangFetch()
        let started = ContinuousClock.now
        await window.backgroundFetchOnce()
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(await git.fetchCancelled)
        #expect(window.changesInFlight.isEmpty)
    }
}
