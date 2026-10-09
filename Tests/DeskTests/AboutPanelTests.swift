import AppKit
import Testing
@testable import Desk

@Test func creditsLinkToTheRepoAndTakibi() {
    let credits = AboutPanel.credits()
    #expect(credits.string.contains("An independent side project that works with Takibi Base."))
    var links: [String] = []
    credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, _, _ in
        if let url = value as? URL { links.append(url.absoluteString) }
    }
    #expect(links == [Brand.repository, Brand.takibiSite])
}
