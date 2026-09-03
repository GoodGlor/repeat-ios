import Foundation

/// Which way a card is asked. A `Note` with `reverse == true` yields both (D2).
enum Direction: String, Codable, CaseIterable, Sendable {
    case forward = "fwd"
    case reverse = "rev"
}
