import Foundation
import Testing
@testable import FloridaCore

struct GoogleMapsLocationTests {
    @Test(arguments: [
        "101 Main St, San Francisco, CA 94105", "Souvla", "Room 404",
        "St. Pancras International\nLondon N1C 4QP", "37.7599, -122.4148",
        "849VQH2C+3R", "Room 4 / Meet", "The Zoom Room",
    ])
    func acceptsPlaceNamesAndAddresses(_ location: String) {
        #expect(GoogleMapsLocation(location)?.name == location)
    }

    @Test(arguments: [
        "", " \n ", "TBD", "N/A", "Remote", "Online  Meeting", " Google Meet ",
        "Zoom call", "phone call", "+1 (415) 555-0100", "tel:+14155550100",
        "https://meet.google.com/abc-defg-hij", "company.zoom.us/j/123",
        "Join at https://teams.microsoft.com/meet/123", "zoommtg://zoom.us/join",
        "https://example.com/location",
    ])
    func rejectsVirtualAndLinkedLocations(_ location: String) {
        #expect(GoogleMapsLocation(location) == nil)
    }

    @Test func preservesExistingWebLinks() {
        let link = "https://meet.google.com/abc-defg-hij?authuser=1&x=2"
        #expect(GoogleMapsLocation.webLink(" \(link)\n")?.absoluteString == link)
        #expect(GoogleMapsLocation.webLink("Join at \(link)") == nil)
    }

    @Test func buildsEncodedAppAndWebURLs() throws {
        let location = try #require(GoogleMapsLocation("  Café & Co. + 1?#/%  "))
        let encoded = "Caf%C3%A9%20%26%20Co.%20%2B%201%3F%23%2F%25"
        #expect(location.url(for: .search, appInstalled: true)?.absoluteString == "comgooglemaps://?q=\(encoded)")
        #expect(location.url(for: .directions, appInstalled: true)?.absoluteString == "comgooglemaps://?daddr=\(encoded)&directionsmode=driving")
        #expect(location.url(for: .search, appInstalled: false)?.absoluteString == "https://www.google.com/maps/search/?api=1&query=\(encoded)")
        #expect(location.url(for: .directions, appInstalled: false)?.absoluteString == "https://www.google.com/maps/dir/?api=1&destination=\(encoded)")
    }
}
