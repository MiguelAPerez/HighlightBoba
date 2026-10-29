import Testing
@testable import HighlightBoba

@Suite struct HighlightBobaTests {
    @Test func versionIsSet() {
        #expect(!HighlightBoba.version.isEmpty)
    }
}
