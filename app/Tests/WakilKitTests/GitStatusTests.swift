import Foundation
import Testing
@testable import WakilKit

@Suite struct GitStatusTests {
    @Test func readsEveryRootInProjectOrderAndOneThatFailsHidesNoOther() async {
        let git = FakeGit()
        await git.set(status: "/p/api", files: [("b.go", "changed", "M"), ("a.go", "staged", "A")])
        let status = GitStatus(git: git, roots: { ["/p/docs", "/p/api"] })
        await status.refresh()
        let roots = await status.roots
        #expect(roots.map(\.root) == ["/p/docs", "/p/api"])
        #expect(roots[0].error == "not a git repository" && roots[0].files.isEmpty)
        #expect(roots[1].files.map(\.path) == ["a.go", "b.go"], "staged before changed")
        #expect(!roots.contains { $0.loading })
    }

    @Test func onlyReadsTheNamedRootAndKeepsTheOthers() async {
        let git = FakeGit()
        for r in ["/p/api", "/p/web"] { await git.set(status: r, files: [("x", "changed", "M")]) }
        let status = GitStatus(git: git, roots: { ["/p/api", "/p/web"] })
        await status.refresh()
        await git.set(status: "/p/web", files: [])
        await status.refresh(only: "/p/api")
        #expect(await git.calls.filter { $0.hasPrefix("git_status") }.count == 3)
        #expect(await status.roots[1].files.map(\.path) == ["x"], "/p/web was not read again")
    }

    @Test func aRootOutsideTheProjectReadsNothing() async {
        let git = FakeGit()
        let status = GitStatus(git: git, roots: { ["/p/api"] })
        await status.refresh(only: "/elsewhere")
        #expect(await git.calls.isEmpty)
    }

    // 3a-i's rule, kept: a slow old reply lands after a newer read and is dropped whole.
    @Test func aReadSupersededByANewerOneLandsNothing() async {
        let git = FakeGit()
        await git.set(status: "/p/api", files: [("old", "changed", "M")])
        await git.setSlowStatus(true)
        let status = GitStatus(git: git, roots: { ["/p/api"] })
        let first = Task { await status.refresh() }
        while await git.statusCount < 1 { await Task.yield() }
        await git.set(status: "/p/api", files: [("new", "changed", "M")])
        let second = Task { await status.refresh() }
        while await git.statusCount < 2 { await Task.yield() }
        await git.releaseStatus(1)
        await second.value
        await git.releaseStatus(0)
        await first.value
        #expect(await status.roots[0].files.map(\.path) == ["new"])
        #expect(await status.roots[0].loading == false)
    }

    @Test func noClientSaysSoUnderEachRoot() async {
        let status = GitStatus(git: nil, roots: { ["/p/api"] })
        await status.refresh()
        #expect(await status.roots[0].error?.contains("git") == true)
    }

    @Test func resetForgetsEveryRoot() async {
        let git = FakeGit()
        await git.set(status: "/p/api", files: [])
        let status = GitStatus(git: git, roots: { ["/p/api"] })
        await status.refresh()
        await status.reset()
        #expect(await status.roots.isEmpty)
    }

    // Fix round 1, item 3 (a): while a read is parked, every root of it shows loading.
    @Test func aParkedReadShowsEveryRootLoading() async {
        let git = FakeGit()
        for r in ["/p/api", "/p/web"] { await git.set(status: r, files: [("x", "changed", "M")]) }
        await git.setSlowStatus(true)
        let status = GitStatus(git: git, roots: { ["/p/api", "/p/web"] })
        let read = Task { await status.refresh() }
        while await git.statusCount < 2 { await Task.yield() }
        let mid = await status.roots
        #expect(mid.map(\.root) == ["/p/api", "/p/web"])
        #expect(mid.allSatisfy { $0.loading })
        await git.releaseStatus(0)
        await git.releaseStatus(1)
        await read.value
        #expect(await status.roots.allSatisfy { !$0.loading })
    }

    // Fix round 1, item 3 (b): the older read released first lands nothing and the root stays loading
    // for the newer read, which then lands its files and ends the loading.
    @Test func anOlderReadReleasedFirstLandsNothingAndLoadingStays() async {
        let git = FakeGit()
        await git.set(status: "/p/api", files: [("old", "changed", "M")])
        await git.setSlowStatus(true)
        let status = GitStatus(git: git, roots: { ["/p/api"] })
        let first = Task { await status.refresh() }
        while await git.statusCount < 1 { await Task.yield() }
        await git.set(status: "/p/api", files: [("new", "changed", "M")])
        let second = Task { await status.refresh() }
        while await git.statusCount < 2 { await Task.yield() }

        await git.releaseStatus(0)
        await first.value
        let mid = await status.roots
        #expect(mid[0].files.isEmpty)
        #expect(mid[0].loading == true)

        await git.releaseStatus(1)
        await second.value
        let done = await status.roots
        #expect(done[0].files.map(\.path) == ["new"])
        #expect(done[0].loading == false)
    }
}
