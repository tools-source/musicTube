import UIKit
import UniformTypeIdentifiers

/// Receives a song shared from another app (e.g. the Shazam app), extracts a
/// search query from the shared text/URL, and hands it to the MusicTube app via
/// its `musictube://search?q=…` URL so MusicTube can search and play the track.
///
/// Code-only extension: `Info.plist` points `NSExtensionPrincipalClass` here, so
/// there is no storyboard and no visible UI — it processes and dismisses.
final class ShareViewController: UIViewController {

    /// Must match `MUSICTUBE_URL_SCHEME` in the app's Secrets.xcconfig.
    private let appURLScheme = "musictube"

    override func viewDidLoad() {
        super.viewDidLoad()
        extractSharedQuery { [weak self] query in
            guard let self else { return }
            if let query, let url = self.makeAppURL(for: query) {
                self.openMainApp(url)
            }
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }

    // MARK: - Extract query

    private func extractSharedQuery(completion: @escaping (String?) -> Void) {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            completion(nil)
            return
        }

        let attachments = items.flatMap { $0.attachments ?? [] }
        let group = DispatchGroup()
        var collectedText: [String] = []
        var collectedURLs: [URL] = []

        for provider in attachments {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    if let url = item as? URL {
                        collectedURLs.append(url)
                    } else if let data = item as? Data,
                              let string = String(data: data, encoding: .utf8),
                              let url = URL(string: string) {
                        collectedURLs.append(url)
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                    if let string = item as? String {
                        collectedText.append(string)
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            completion(Self.bestQuery(fromText: collectedText, urls: collectedURLs))
        }
    }

    /// Prefers cleaned share text (Shazam shares "I used Shazam to discover X by Y"),
    /// then falls back to a Shazam URL slug (e.g. `.../track/123/blinding-lights`).
    static func bestQuery(fromText texts: [String], urls: [URL]) -> String? {
        for text in texts {
            if let cleaned = cleanShareText(text) {
                return cleaned
            }
        }
        for url in urls {
            if let slug = songSlug(from: url) {
                return slug
            }
        }
        return nil
    }

    private static func cleanShareText(_ raw: String) -> String? {
        var text = raw

        // Remove any URLs embedded in the shared text.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range).reversed() {
                if let matchRange = Range(match.range, in: text) {
                    text.removeSubrange(matchRange)
                }
            }
        }

        // Strip common Shazam boilerplate (best-effort, locale-tolerant).
        let boilerplate = [
            "I used Shazam to discover",
            "I used #Shazam to discover",
            "Discovered with Shazam",
            "#Shazam",
            "Shazam"
        ]
        for phrase in boilerplate {
            text = text.replacingOccurrences(of: phrase, with: " ", options: [.caseInsensitive])
        }

        text = text.replacingOccurrences(of: "\n", with: " ")
        let collapsed = text.split(separator: " ").joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " .#-–—:\"“”"))
        return trimmed.count >= 2 ? trimmed : nil
    }

    private static func songSlug(from url: URL) -> String? {
        guard let host = url.host?.lowercased(), host.contains("shazam") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" && $0.isEmpty == false }
        guard let last = parts.last, last.rangeOfCharacter(from: .letters) != nil else { return nil }
        let words = last
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return words.count >= 2 ? words : nil
    }

    // MARK: - Open host app

    private func makeAppURL(for query: String) -> URL? {
        var components = URLComponents()
        components.scheme = appURLScheme
        components.host = "search"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url
    }

    /// Share extensions can't use `UIApplication.shared`, so walk the responder
    /// chain to reach the running `UIApplication` and open the host app.
    private func openMainApp(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = current.next
        }
    }
}
