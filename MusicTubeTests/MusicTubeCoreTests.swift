import XCTest
@testable import MusicTube

final class MusicTubeCoreTests: XCTestCase {
    func testQueryValidationTrimsAndRejectsInvalidInput() throws {
        XCTAssertEqual(try QueryValidator.validateSearchQuery("  Massive Attack  "), "Massive Attack")
        XCTAssertThrowsError(try QueryValidator.validateSearchQuery("   "))
        XCTAssertThrowsError(
            try QueryValidator.validateSearchQuery(String(repeating: "a", count: AppConfig.Search.maxQueryLength + 1))
        )
    }

    func testArabicSearchNormalizationIsDeterministic() {
        XCTAssertEqual(SearchTextNormalizer.normalized("  إِلَى السَّماء  "), "الي السماء")
        XCTAssertEqual(SearchTextNormalizer.tokens(from: "Beyoncé — Halo"), ["beyonce", "halo"])
    }

    func testUnavailableAndShortFormTracksAreFiltered() {
        let unavailable = Track(title: "[Deleted video]", artist: "", youtubeVideoID: "deleted")
        let short = Track(title: "Song #Shorts", artist: "Artist", duration: 30, youtubeVideoID: "short")
        let song = Track(title: "Full Song", artist: "Artist", duration: 210, youtubeVideoID: "song")

        XCTAssertEqual([unavailable, short, song].playableOnly().map(\.id), [short.id, song.id])
        XCTAssertEqual([short, song].withoutShorts().map(\.id), [song.id])
    }

    func testAICurationRequiresExplicitOptIn() {
        let suiteName = "MusicTubeCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = DataUsageSettings(defaults: defaults)
        XCTAssertFalse(settings.personalizedAICuration)
        settings.personalizedAICuration = true
        XCTAssertTrue(defaults.bool(forKey: "Privacy.personalizedAICuration"))
    }
}
