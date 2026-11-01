import Foundation

/// A video call link found in a calendar event, for one-click joining.
public struct MeetingLink: Equatable, Hashable, Sendable {
    public enum Service: String, Sendable, CaseIterable {
        case zoom = "Zoom"
        case meet = "Google Meet"
        case teams = "Teams"
        case webex = "Webex"
        case faceTime = "FaceTime"
        case slack = "Slack"
        case whereby = "Whereby"
    }

    public var url: URL
    public var service: Service

    public init(url: URL, service: Service) {
        self.url = url
        self.service = service
    }

    /// The first call link in the event's URL, location or notes, in that
    /// order (the URL field is the most deliberate). Ignores ordinary links.
    public static func find(in fields: [String?]) -> MeetingLink? {
        for field in fields {
            guard let text = field, !text.isEmpty,
                  let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { continue }
            let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                guard let url = match.url, let link = MeetingLink(url) else { continue }
                return link
            }
        }
        return nil
    }

    /// Recognises a URL as a call link.
    public init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }

        let service: Service?
        if on("zoom.us") || on("zoomgov.com") {
            service = path.hasPrefix("/j/") || path.hasPrefix("/my/") || path.hasPrefix("/w/") ? .zoom : nil
        } else if host == "meet.google.com" {
            service = path.count > 1 ? .meet : nil
        } else if on("teams.microsoft.com") || on("teams.live.com") {
            service = path.contains("meetup-join") || path.hasPrefix("/meet/") || path.hasPrefix("/l/meet") ? .teams : nil
        } else if on("webex.com") {
            service = path.contains("/meet") || path.contains("/j.php") || path.contains("/join") ? .webex : nil
        } else if host == "facetime.apple.com" {
            service = path.hasPrefix("/join") ? .faceTime : nil
        } else if host == "app.slack.com" {
            service = path.hasPrefix("/huddle") ? .slack : nil
        } else if on("whereby.com") {
            service = path.count > 1 ? .whereby : nil
        } else {
            service = nil
        }
        guard let service else { return nil }
        self.init(url: url, service: service)
    }
}
