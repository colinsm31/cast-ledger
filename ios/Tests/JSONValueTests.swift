// MARK: - JSONValueTests
//
// Unit tests for the JSONB ↔ Swift mapping. Validates round-tripping and the
// flexible spec_values shape used by pieces, plus lenient enum decoding.
// AAA pattern (arrange / act / assert), public-API only.

import XCTest
@testable import CastLedger

final class JSONValueTests: XCTestCase {

    // MARK: - Properties

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // MARK: - spec_values decoding

    func testDecodesPieceSpecValuesObject() throws {
        // Arrange — the seed's EVG-D14 spec_values shape.
        let json = """
        {"length_ft":40,"width_ft":8,"thickness_in":14,"target_psi":5000,"water_test":"required"}
        """.data(using: .utf8)!

        // Act
        let value = try decoder.decode(JSONValue.self, from: json)

        // Assert
        XCTAssertEqual(value["length_ft"]?.doubleValue, 40)
        XCTAssertEqual(value["water_test"]?.stringValue, "required")
        XCTAssertNil(value["nonexistent"])
    }

    func testRoundTripsArbitraryJSON() throws {
        // Arrange
        let json = """
        {"a":1,"b":"two","c":true,"d":null,"e":[1,2,3],"f":{"g":9.5}}
        """.data(using: .utf8)!

        // Act
        let value = try decoder.decode(JSONValue.self, from: json)
        let reEncoded = try encoder.encode(value)
        let reDecoded = try decoder.decode(JSONValue.self, from: reEncoded)

        // Assert — semantic equality survives the round trip.
        XCTAssertEqual(value, reDecoded)
        XCTAssertEqual(value["e"]?.arrayValue?.count, 3)
        XCTAssertEqual(value["f"]?["g"]?.doubleValue, 9.5)
        XCTAssertTrue(value["d"]?.isNull ?? false)
    }

    // MARK: - Lenient enum decoding

    func testUnknownStatusDecodesToUnknownNotCrash() throws {
        // Arrange — a status value an older client doesn't know.
        let json = "\"some_future_status\"".data(using: .utf8)!

        // Act
        let status = try decoder.decode(PieceStatus.self, from: json)

        // Assert
        XCTAssertEqual(status, .unknown)
    }

    func testKnownStatusDecodesAndAdvances() throws {
        // Arrange
        let json = "\"curing\"".data(using: .utf8)!

        // Act
        let status = try decoder.decode(PieceStatus.self, from: json)

        // Assert
        XCTAssertEqual(status, .curing)
        XCTAssertEqual(status.next, .qc)
    }
}
