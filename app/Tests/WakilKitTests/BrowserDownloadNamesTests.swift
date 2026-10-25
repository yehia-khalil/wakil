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
