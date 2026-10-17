import Testing
@testable import WakilKit

/// What a diff tab's banner says the diff cannot show by itself (3a-i's, moved to the editor with
/// `gitDiffBanner` in 3b-iii).

private func diff(_ original: String = "a", _ modified: String = "b", language: String = "swift",
                  loading: Bool = false, error: String? = nil, binary: Bool = false) -> GitDiffState {
    GitDiffState(original: original, modified: modified, language: language, binary: binary,
                 bytes: 0, lines: 1, truncated: false, error: error, loading: loading)
}

@Test func banners() {
    var d = GitDiffState(original: "", modified: "", language: "plaintext", binary: true, bytes: 2_202_009,
                         lines: 0, truncated: false, error: nil, loading: false)
    #expect(gitDiffBanner(d) == "binary · 2.1 MB")
    // R9: `git_show` cuts each side at 2 MB of bytes, and `bytes` is the larger side's true size.
    d.binary = false; d.bytes = 3_145_728; d.truncated = true
    #expect(gitDiffBanner(d) == "file is 3.0 MB · first 2 MB shown")
    d.truncated = false
    #expect(gitDiffBanner(d) == nil)
}

@Test func smallBinarySizes() {
    var d = diff(binary: true)
    d.bytes = 512
    #expect(gitDiffBanner(d) == "binary · 512 bytes")
    d.bytes = 20_480
    #expect(gitDiffBanner(d) == "binary · 20 KB")
}
