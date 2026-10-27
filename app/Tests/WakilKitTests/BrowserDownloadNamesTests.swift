import Foundation
import Testing
@testable import WakilKit

private let folder = URL(fileURLWithPath: "/tmp/dl", isDirectory: true)

private func destination(_ suggested: String, taken: Set<String> = []) -> String {
    browserDownloadDestination(in: folder, suggested: suggested) { taken.contains($0.lastPathComponent) }
        .lastPathComponent
}

@Test func aSuggestedNameIsCutToOneNameInTheFolder() {
    #expect(destination("../x") == "x")
    #expect(destination("..") == "download")
    #expect(destination("") == "download")
    #expect(destination("/") == "download")
    #expect(destination("a/b/report.pdf") == "report.pdf")
    #expect(browserDownloadDestination(in: folder, suggested: "../../etc/x") { _ in false }.deletingLastPathComponent().path == folder.path)
}

@Test func aTakenNameIsNumberedAsFinderDoes() {
    #expect(destination("name.ext", taken: ["name.ext"]) == "name 2.ext")
    #expect(destination("name.ext", taken: ["name.ext", "name 2.ext"]) == "name 3.ext")
    #expect(destination("README", taken: ["README"]) == "README 2")
}

@Test func theSizeLineCountsAsFinderDoes() {
    #expect(browserDownloadSize(received: 12_400_000, expected: 80_000_000, state: .running) == "12.4 of 80 MB")
    #expect(browserDownloadSize(received: 1_000, expected: -1, state: .running) == "1 KB")
    #expect(browserDownloadSize(received: 10_485_760, expected: 10_485_760, state: .finished) == "10.5 MB")
    #expect(browserDownloadSize(received: 2_500_000_000, expected: 2_500_000_000, state: .finished) == "2.5 GB")
}

@Test func theStatusLineSaysWhatIsHappeningToTheDownload() {
    func download(_ state: BrowserDownload.State, received: Int64 = 12_400_000, expected: Int64 = 80_000_000,
                  path: String? = nil, failure: String? = nil) -> BrowserDownload {
        BrowserDownload(id: "d1", filename: "a.bin", received: received, expected: expected, state: state,
                        path: path, failure: failure)
    }
    #expect(browserDownloadStatus(download(.running)) == "Downloading · 12.4 of 80 MB")
    #expect(browserDownloadStatus(download(.running, received: 1_000, expected: -1)) == "Downloading · 1 KB")
    #expect(browserDownloadStatus(download(.finished, received: 80_000_000)) == "Downloaded · 80 MB")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Fetched")
    #expect(browserDownloadStatus(download(.finished, received: 80_000_000, path: folder.appendingPathComponent("a.bin").path))
        == "Downloaded · 80 MB to Fetched")
    #expect(browserDownloadStatus(download(.cancelled)) == "Cancelled")
    #expect(browserDownloadStatus(download(.failed, failure: "The network connection was lost.")) == "The network connection was lost.")
}

@Test func theBarFillsWithTheBytesOfARunningDownloadOfKnownSize() {
    func fraction(_ state: BrowserDownload.State, _ received: Int64, _ expected: Int64) -> Double? {
        browserDownloadFraction(BrowserDownload(id: "d1", filename: "a", received: received, expected: expected, state: state))
    }
    #expect(fraction(.running, 20, 80) == 0.25)
    #expect(fraction(.running, 90, 80) == 1)
    #expect(fraction(.running, 20, -1) == nil)
    #expect(fraction(.finished, 80, 80) == nil)
    #expect(fraction(.cancelled, 20, 80) == nil)
}
