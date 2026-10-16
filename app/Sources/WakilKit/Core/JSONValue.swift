import Foundation

/// A JSON value tree, used for the untyped `params`/`result`/`data` fields of
/// a JSON-RPC message. Mirrors Foundation's JSON model without relying on
/// `Any`, so it can conform to `Sendable` and `Equatable`.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    /// A whole number, held exactly.
    ///
    /// **Tried before `number` when decoding**, because a `Double` cannot
    /// represent every integer past 2^53: a database key of
    /// 9007199254740993 arrived as ...992, and an `UPDATE` composed from it
    /// named a different row. JSON has one number type; Wakil needs two
    /// cases to hold it without lying, and the JSON-RPC id enum in this
    /// same file has decoded `Int` before `String` since Phase 2a for the
    /// same reason.
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int64.self) {
            self = .integer(i)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .integer(let i): try container.encode(i)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

extension JSONValue {
    /// Two numeric cases hold one number between them, so they compare
    /// **by value, across cases**: `.integer(5) == .number(5)`.
    ///
    /// **Hand-written rather than synthesised**, because `app/Tests`
    /// constructs `.number(…)` 236 times as an expected value, and after
    /// the decoder change the actual value arrives as `.integer`. The
    /// synthesised operator would fail every one of those for a reason
    /// that is not a bug.
    ///
    /// **The comparison narrows the `Double` to an `Int64`, never the
    /// other way.** `Double(9007199254740993)` is `9007199254740992.0`, so
    /// widening the integer would call two distinct keys equal — the exact
    /// defect this case was added to remove, reintroduced inside the
    /// operator that is supposed to tell them apart.
    ///
    /// **`Hashable` is deliberately NOT added.** `JSONValue` does not
    /// conform today. If it ever does, `hash(into:)` must hash `.integer(5)`
    /// and `.number(5)` identically, or a dictionary will hold two entries
    /// this operator says are one.
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case (.bool(let l), .bool(let r)):
            return l == r
        case (.integer(let l), .integer(let r)):
            return l == r
        case (.number(let l), .number(let r)):
            return l == r
        case (.integer(let i), .number(let d)), (.number(let d), .integer(let i)):
            guard let narrowed = Int64(exactly: d) else { return false }
            return narrowed == i
        case (.string(let l), .string(let r)):
            return l == r
        case (.array(let l), .array(let r)):
            return l == r
        case (.object(let l), .object(let r)):
            return l == r
        default:
            return false
        }
    }
}

/// Narrows a JSON number to an `Int`, or `nil` if it cannot be represented
/// exactly as one.
///
/// **Why this exists at all.** `Int(Double.nan)` and `Int(1e300)` both
/// *trap* rather than throwing — they do not return a wrong answer, they
/// take the process down. A JSON number reaches Wakil from three places
/// that are all outside its control: an agent's `tools/call` arguments, a
/// `--dispatch` script, and a snapshot read back off disk. Any of them can
/// carry a `NaN` or an out-of-range magnitude in a field something reads as
/// an index, and the difference between a refusal and a crash is this
/// guard.
///
/// **It lives here, beside `JSONValue`, because both layers need it.** It
/// was written for `paneTable(from:)` (the view's projection) and left
/// `private` there, while `requireRowIndex` — the surface an agent actually
/// types a row number into — converted with a bare `Int(number)` and
/// trapped on `1e300` (verified: SIGTRAP, exit 133). That is the projection
/// hardened and the entrance left open, and it is the shape a second copy
/// of this function would have recreated. One copy, reachable from both.
///
/// The `1e15` bound is the same one `PaneCell`'s number branch guards with,
/// reused rather than reinvented so the numeric guards in this module
/// cannot drift apart: past it a `Double` can no longer represent every
/// integer exactly, so an `Int` made from one would assert a precision the
/// value does not have.
func safeInt(_ value: Double) -> Int? {
    guard value.isFinite, value == value.rounded(), abs(value) < 1e15 else { return nil }
    return Int(value)
}

/// `Int64` counterpart of `safeInt`, for millisecond timings — see that
/// function's doc comment for why the guard is here at all.
func safeInt64(_ value: Double) -> Int64? {
    guard value.isFinite, value == value.rounded(), abs(value) < 1e15 else { return nil }
    return Int64(value)
}

/// The three ways anything outside this file reads a number out of a
/// `JSONValue`.
///
/// **They exist so that adding a numeric case cannot break a reader
/// silently.** `if case .number(let n)? = object["offset"]` does not fail
/// to compile when a second numeric case appears — it compiles, runs, and
/// takes the `else` branch for every integer that arrives. An accessor has
/// one implementation, in one file, and gains the new case there once.
///
/// `intValue` and `int64Value` apply `safeInt`/`safeInt64`'s guards to the
/// `.number` path unchanged: a fraction, a `NaN`, an infinity and anything
/// at or past `1e15` are refused rather than converted, because `Int(_:)`
/// *traps* on them rather than returning a wrong answer.
extension JSONValue {
    /// This value as a `Double`, or `nil` if it is not a number.
    public var doubleValue: Double? {
        switch self {
        case .integer(let i): return Double(i)
        case .number(let n): return n
        default: return nil
        }
    }

    /// This value as an `Int64`, or `nil` if it is not a number that can be
    /// one exactly.
    public var int64Value: Int64? {
        switch self {
        case .integer(let i): return i
        case .number(let n): return safeInt64(n)
        default: return nil
        }
    }

    /// This value as an `Int`, or `nil` if it is not a number that can be
    /// one exactly.
    public var intValue: Int? {
        switch self {
        // An Int64 is already exact; only the conversion to the platform
        // Int can fail, and on a 64-bit platform it cannot.
        case .integer(let i): return Int(exactly: i)
        case .number(let n): return safeInt(n)
        default: return nil
        }
    }
}

/// Shared helpers so `JSONValue?` fields distinguish "key absent" (`nil`)
/// from "key present and JSON `null`" (`.some(.null)`) instead of collapsing
/// both to `nil` the way `decodeIfPresent`/`encodeIfPresent` would.
extension KeyedDecodingContainer {
    func decodeJSONValuePreservingNull(forKey key: Key) throws -> JSONValue? {
        guard contains(key) else { return nil }
        if try decodeNil(forKey: key) { return .null }
        return try decode(JSONValue.self, forKey: key)
    }
}

extension KeyedEncodingContainer {
    mutating func encodeJSONValuePreservingNull(_ value: JSONValue?, forKey key: Key) throws {
        guard let value else { return }
        try encode(value, forKey: key)
    }
}
