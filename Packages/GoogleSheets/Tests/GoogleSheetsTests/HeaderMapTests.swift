import XCTest
@testable import GoogleSheets

/// Card #13, header half (§3.1).
final class HeaderMapTests: XCTestCase {

    private let full = ["id", "front", "back", "example", "tags", "reverse", "updated_at", "deleted"]

    func testColumnsResolveByNameNotPosition() throws {
        // Same columns, reordered — which is what happens the first time the owner
        // drags a column in Sheets.
        let map = try HeaderMap(headerRow: ["back", "reverse", "front", "id"])
        let row = ["неохочий", "TRUE", "reluctant", "uuid-1"]

        XCTAssertEqual(map.value("front", in: row), "reluctant")
        XCTAssertEqual(map.value("back", in: row), "неохочий")
        XCTAssertEqual(map.value("id", in: row), "uuid-1")
        XCTAssertTrue(map.boolean("reverse", in: row))
    }

    func testHeadersAreMatchedCaseInsensitivelyAndTrimmed() throws {
        let map = try HeaderMap(headerRow: [" Front ", "BACK", "Id"])
        XCTAssertEqual(map.value("front", in: ["a", "b", "c"]), "a")
        XCTAssertEqual(map.value("back", in: ["a", "b", "c"]), "b")
        XCTAssertEqual(map.value("ID", in: ["a", "b", "c"]), "c")
    }

    func testMissingRequiredColumnsAreNamed() {
        XCTAssertThrowsError(try HeaderMap(headerRow: ["id", "front", "tags"])) {
            XCTAssertEqual($0 as? HeaderMap.Failure, .missingRequiredColumn("back"))
        }
        XCTAssertThrowsError(try HeaderMap(headerRow: ["id", "back"])) {
            XCTAssertEqual($0 as? HeaderMap.Failure, .missingRequiredColumn("front"))
        }
        XCTAssertThrowsError(try HeaderMap(headerRow: [])) {
            XCTAssertEqual($0 as? HeaderMap.Failure, .emptyHeaderRow)
        }
        XCTAssertThrowsError(try HeaderMap(headerRow: ["", " "])) {
            XCTAssertEqual($0 as? HeaderMap.Failure, .emptyHeaderRow)
        }
    }

    /// Two `back` columns give no way to know which the owner means, so guessing
    /// would silently show the wrong answer on half the cards.
    func testADuplicateColumnIsAmbiguousAndRejected() {
        XCTAssertThrowsError(try HeaderMap(headerRow: ["front", "back", "Back"])) {
            XCTAssertEqual($0 as? HeaderMap.Failure, .duplicateColumn("back"))
        }
    }

    // MARK: - Extras (D1)

    func testUnknownColumnsBecomeExtrasInSheetOrder() throws {
        let map = try HeaderMap(headerRow: ["id", "front", "back", "вимова", "синоніми"])
        XCTAssertEqual(map.extraColumns, ["вимова", "синоніми"])

        let row = ["uuid", "reluctant", "неохочий", "/rɪˈlʌktənt/", ""]
        let extras = map.extras(in: row)
        XCTAssertEqual(extras.order, ["вимова", "синоніми"], "display order is the sheet's column order")
        XCTAssertEqual(extras.values, ["вимова": "/rɪˈlʌktənt/"], "empty extras carry no value")
    }

    func testNoneOfTheKnownColumnsAreTreatedAsExtras() throws {
        XCTAssertTrue(try HeaderMap(headerRow: full).extraColumns.isEmpty)
    }

    // MARK: - Ragged rows

    /// Google omits trailing empty cells, so short rows are the norm, not an edge
    /// case.
    func testShortRowsReadAsNilRatherThanCrashing() throws {
        let map = try HeaderMap(headerRow: full)
        let row = ["uuid", "reluctant", "неохочий"]
        XCTAssertEqual(map.value("front", in: row), "reluctant")
        XCTAssertNil(map.value("example", in: row))
        XCTAssertNil(map.value("deleted", in: row))
        XCTAssertFalse(map.boolean("reverse", in: row))
        XCTAssertTrue(map.boolean("reverse", in: row, default: true), "the default is honoured")
    }

    func testBooleanAcceptsWhatPeopleActuallyType() throws {
        let map = try HeaderMap(headerRow: ["front", "back", "reverse"])
        for truthy in ["TRUE", "true", " True ", "yes", "1", "так"] {
            XCTAssertTrue(map.boolean("reverse", in: ["a", "b", truthy]), truthy)
        }
        for falsy in ["FALSE", "false", "0", "no", ""] {
            XCTAssertFalse(map.boolean("reverse", in: ["a", "b", falsy]), falsy)
        }
    }
}

/// Card #13, `_meta` half (§3.1).
final class MetaSheetTests: XCTestCase {

    func testKeyValueRowsAreRead() {
        let meta = MetaSheet.parse(rows: [
            ["key", "value"],
            ["schema_version", "1"],
            ["desired_retention", "0.87"],
            ["fsrs_params", "[0.1, 0.2]"],
        ])
        XCTAssertEqual(meta.schemaVersion, "1")
        XCTAssertEqual(meta.rawDesiredRetention, "0.87")
        XCTAssertEqual(meta.rawFSRSParams, "[0.1, 0.2]")
    }

    /// This tab is edited by hand, so blank rows and stray whitespace are normal
    /// and must not be treated as failures.
    func testBlankRowsAndWhitespaceAreTolerated() {
        let meta = MetaSheet.parse(rows: [
            [],
            ["", "orphan value"],
            ["  desired_retention  ", "  0.9  "],
            ["schema_version"],
        ])
        XCTAssertEqual(meta.rawDesiredRetention, "0.9")
        XCTAssertNil(meta.schemaVersion, "a key with no value reads as absent, not empty string")
    }

    func testKeysAreCaseInsensitive() {
        XCTAssertEqual(MetaSheet.parse(rows: [["Desired_Retention", "0.9"]]).rawDesiredRetention, "0.9")
    }

    func testAnAbsentMetaTabYieldsNothingRatherThanDefaultsThatLookConfigured() {
        let meta = MetaSheet.parse(rows: [])
        XCTAssertNil(meta.schemaVersion)
        XCTAssertNil(meta.rawFSRSParams)
        XCTAssertNil(meta.rawDesiredRetention)
    }
}
