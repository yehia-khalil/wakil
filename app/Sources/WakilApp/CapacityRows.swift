import SwiftUI
import WakilKit

private let coolWhite = Color(red: 0.910, green: 0.925, blue: 0.965)          // #e8ecf6
private let violet = Color(red: 0.486, green: 0.361, blue: 1.0)                // #7c5cff
private let amber = Color(red: 0.910, green: 0.706, blue: 0.353)               // #e8b45a, §5 caution

/// One account: name, then a 5H and a WEEK line — bar, percent left, reset.
/// Bars show what is left; amber at 20% or less; never red.
struct CapacityRows: View {
    let readings: [CapacityReading]
    let inUse: String
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(readings) { reading in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(reading.account).font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(coolWhite.opacity(0.92))
                        if reading.account == inUse {
                            Text("IN USE").font(.system(size: 8, weight: .medium)).tracking(1.4)
                                .foregroundStyle(violet.opacity(0.9))
                        }
                    }
                    switch reading.state {
                    case .read:
                        if let w = reading.fiveHour { line("5H", w) }
                        if let w = reading.sevenDay { line("WEEK", w) }
                        if let w = reading.month { line("MONTH", w) }
                        if let asOf = reading.asOf {
                            Text(CapacityDisplay.asOfLabel(asOf)).font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(coolWhite.opacity(0.3))
                        }
                    case .notRead: note("not read yet")
                    case .noLimits: note("no limits")
                    case .error: note(reading.error ?? "capacity unreadable", tone: amber)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("capacity.row.\(reading.account)")
            }
        }
    }

    private func line(_ name: String, _ w: CapacityWindow) -> some View {
        let reset = CapacityDisplay.hasReset(w, now: now)
        let tone = (!reset && CapacityDisplay.isLow(w)) ? amber : coolWhite.opacity(0.72)
        return HStack(spacing: 8) {
            Text(name).frame(width: 42, alignment: .leading).foregroundStyle(coolWhite.opacity(0.38))
            ZStack(alignment: .leading) {
                Capsule().fill(coolWhite.opacity(0.08))
                if !reset {
                    GeometryReader { g in
                        Capsule().fill(CapacityDisplay.isLow(w) ? amber : violet)
                            .frame(width: g.size.width * CGFloat(w.percentLeft) / 100)
                    }
                }
            }
            .frame(width: 96, height: 3)
            Text(reset ? "reset \(CapacityDisplay.resetLabel(w.resetsAt, now: now)) · not read since"
                       : "\(w.percentLeft)% · \(CapacityDisplay.resetLabel(w.resetsAt, now: now))")
                .foregroundStyle(tone)
        }
        .font(.system(size: 10.5, design: .monospaced))
    }

    private func note(_ text: String, tone: Color = coolWhite.opacity(0.55)) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(tone).fixedSize(horizontal: false, vertical: true)
    }
}
