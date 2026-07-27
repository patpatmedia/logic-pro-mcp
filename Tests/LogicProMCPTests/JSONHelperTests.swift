import XCTest

@testable import LogicProMCP

/// Pure-logic tests. Everything that touches the Accessibility API needs a running
/// Logic Pro and is exercised live instead.
final class JSONHelperTests: XCTestCase {
    func testJSONStringEscapesQuotesAndBackslashes() {
        XCTAssertEqual(jsonString("Hörspiel JONA"), "\"Hörspiel JONA\"")
        XCTAssertEqual(jsonString("Say \"hi\""), "\"Say \\\"hi\\\"\"")
        XCTAssertEqual(jsonString("path\\to"), "\"path\\\\to\"")
        XCTAssertEqual(jsonString("line\nbreak"), "\"line\\nbreak\"")
    }

    /// An unreadable fader must serialise as null, never as 0 — a 0 is
    /// indistinguishable from a genuinely silenced track.
    func testUnreadableVolumeEncodesAsNull() throws {
        let track = TrackState(id: 0, name: "Szene 1", type: .unknown)
        let json = encodeJSON(track)
        XCTAssertTrue(json.contains("\"volume\" : null"), json)
        XCTAssertTrue(json.contains("\"pan\" : null"), json)
    }

    func testReadableVolumeStillEncodesItsValue() throws {
        var track = TrackState(id: 0, name: "Szene 1", type: .audio)
        track.volume = 173
        track.pan = 64
        let json = encodeJSON(track)
        XCTAssertTrue(json.contains("\"volume\" : 173"), json)
        XCTAssertTrue(json.contains("\"pan\" : 64"), json)
    }
}
