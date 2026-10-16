import Foundation

/// How much of one provider account's rate-limit windows is left, as
/// `wakil-ctx`'s `capacity` tool answers it. Times arrive as RFC 3339 UTC
/// with whole seconds (`internal/wakilcore/capacity.go`).
public struct CapacityWindow: Codable, Sendable, Equatable {
    public let percentLeft: Int
    public let resetsAt: Date
    public init(percentLeft: Int, resetsAt: Date) {
        self.percentLeft = percentLeft
        self.resetsAt = resetsAt
    }
}

/// The pair one `rate_limit_event` carries. The weekly window may be absent;
/// the 5-hour one never is, or there is no reading at all.
public struct CapacityWindows: Sendable, Equatable {
    public let fiveHour: CapacityWindow
    public let sevenDay: CapacityWindow?
    public init(fiveHour: CapacityWindow, sevenDay: CapacityWindow?) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

public struct CapacityReading: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable { case read, notRead, noLimits, error }
    public let account: String
    public let kind: String
    public let state: State
    public let fiveHour: CapacityWindow?
    public let sevenDay: CapacityWindow?
    public let month: CapacityWindow?
    public let asOf: Date?
    public let error: String?
    public var id: String { account }
    public init(account: String, kind: String, state: State, fiveHour: CapacityWindow?,
                sevenDay: CapacityWindow?, month: CapacityWindow? = nil, asOf: Date?, error: String?) {
        self.account = account; self.kind = kind; self.state = state
        self.fiveHour = fiveHour; self.sevenDay = sevenDay; self.month = month
        self.asOf = asOf; self.error = error
    }
}

public struct CapacityListing: Codable, Sendable, Equatable {
    public let readings: [CapacityReading]
}

public func decodeCapacityListing(fromResult result: JSONValue?) -> CapacityListing? {
    guard case .object(let object)? = result,
          case .object(let structured)? = object["structuredContent"],
          structured["readings"] != nil,
          let data = try? JSONEncoder().encode(JSONValue.object(structured))
    else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(CapacityListing.self, from: data)
}

private func rfc3339(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)))
}

private func windowJSON(_ w: CapacityWindow) -> JSONValue {
    .object(["percentLeft": .integer(Int64(w.percentLeft)), "resetsAt": .string(rfc3339(w.resetsAt))])
}

/// `record_capacity`'s arguments for one stream reading.
public func capacityRecordParams(provider: String, windows: CapacityWindows, asOf: Date) -> JSONValue {
    var fields: [String: JSONValue] = [
        "provider": .string(provider),
        "fiveHour": windowJSON(windows.fiveHour),
        "asOf": .string(rfc3339(asOf)),
    ]
    if let week = windows.sevenDay { fields["sevenDay"] = windowJSON(week) }
    return .object(fields)
}
