import Foundation
import IsleKit
import Testing

struct MeetingLinkTests {
    @Test(arguments: [
        ("https://us02web.zoom.us/j/81234567890?pwd=abc", MeetingLink.Service.zoom),
        ("https://meet.google.com/abc-defg-hij", .meet),
        ("https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0", .teams),
        ("https://teams.live.com/meet/9876543210", .teams),
        ("https://acme.webex.com/meet/jane", .webex),
        ("https://facetime.apple.com/join#v=1&p=abc", .faceTime),
        ("https://whereby.com/acme-standup", .whereby),
    ])
    func recognisesCallLinks(_ link: String, _ service: MeetingLink.Service) {
        #expect(MeetingLink(URL(string: link)!)?.service == service)
    }

    @Test(arguments: [
        "https://zoom.us/pricing",
        "https://meet.google.com/",
        "https://teams.microsoft.com/",
        "https://example.com/j/123",
        "zoommtg://zoom.us/join?confno=1",
    ])
    func ignoresOrdinaryLinks(_ link: String) {
        #expect(MeetingLink(URL(string: link)!) == nil)
    }

    @Test func findsLinkInNotesText() {
        let notes = """
        Agenda: https://docs.example.com/agenda
        Join Zoom Meeting
        https://zoom.us/j/1234567890?pwd=xyz
        """
        #expect(MeetingLink.find(in: [nil, "Room 4", notes])?.url.absoluteString == "https://zoom.us/j/1234567890?pwd=xyz")
    }

    @Test func prefersTheEventURLField() {
        let link = MeetingLink.find(in: ["https://meet.google.com/aaa-bbbb-ccc", "https://zoom.us/j/1"])
        #expect(link?.service == .meet)
    }

    @Test func nothingWithoutACallLink() {
        #expect(MeetingLink.find(in: [nil, "Conference room B", "Bring snacks: https://example.com"]) == nil)
    }
}
