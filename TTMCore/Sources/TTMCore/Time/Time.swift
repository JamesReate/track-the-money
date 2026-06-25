import Foundation

/// Unix seconds, UTC. All persisted timestamps use this; display-time-zone
/// conversion happens in the app layer, never in TTMCore.
public typealias UnixTime = Int64

public enum Time {
    public static func date(_ t: UnixTime) -> Date { Date(timeIntervalSince1970: TimeInterval(t)) }
    public static func unix(_ date: Date) -> UnixTime { Int64(date.timeIntervalSince1970) }

    public static let secondsPerDay: Int64 = 86_400
    public static let secondsPerWeek: Int64 = 7 * 86_400
}
