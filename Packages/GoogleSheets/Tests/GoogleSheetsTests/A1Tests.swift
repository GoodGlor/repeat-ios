import XCTest
@testable import GoogleSheets

/// Small, but wrong exactly once at the 26th column — which is a sheet width
/// people really reach, and the failure would write a value into the wrong cell.
final class A1Tests: XCTestCase {

    func testColumnLettersRollOverCorrectly() {
        XCTAssertEqual(A1.column(0), "A")
        XCTAssertEqual(A1.column(25), "Z")
        XCTAssertEqual(A1.column(26), "AA", "the off-by-one everyone writes")
        XCTAssertEqual(A1.column(27), "AB")
        XCTAssertEqual(A1.column(51), "AZ")
        XCTAssertEqual(A1.column(52), "BA")
        XCTAssertEqual(A1.column(701), "ZZ")
        XCTAssertEqual(A1.column(702), "AAA")
    }

    func testTitlesAreQuotedOnlyWhenA1RequiresIt() {
        XCTAssertEqual(A1.quote("Verbs"), "Verbs")
        XCTAssertEqual(A1.quote("_log"), "_log")
        XCTAssertEqual(A1.quote("Phrasal verbs"), "'Phrasal verbs'")
        XCTAssertEqual(A1.quote("Bob's deck"), "'Bob''s deck'", "apostrophes double")
    }

    func testCellAndRowRanges() {
        XCTAssertEqual(A1.cell(sheet: "Verbs", column: 0, row: 7), "Verbs!A7")
        XCTAssertEqual(A1.cell(sheet: "Phrasal verbs", column: 26, row: 2), "'Phrasal verbs'!AA2")
        XCTAssertEqual(A1.row(sheet: "Verbs", width: 8, row: 3), "Verbs!A3:H3")
        XCTAssertEqual(A1.allRows(sheet: "Verbs"), "Verbs!A:ZZ")
    }
}

/// Regression for a bug the scripted transport could not catch: it does not parse
/// ranges, so only Google rejected `Sheet1%21A%3AZZ` with `Unable to parse range`.
extension A1Tests {

    func testRangesAreEscapedForUseAsAPathSegment() {
        // `:` must be escaped so it cannot be read as the `:append` verb…
        XCTAssertEqual(A1.pathEscaped("Sheet1!A:ZZ"), "Sheet1!A%3AZZ")
        // …while `!` and quotes must stay literal, because Google requires them.
        XCTAssertEqual(A1.pathEscaped("'Phrasal verbs'!A:ZZ"), "'Phrasal%20verbs'!A%3AZZ")
        XCTAssertFalse(A1.pathEscaped("Sheet1!A:ZZ").contains("%21"), "! must not be escaped")
    }
}
