import SwiftUI
import WakilKit

private let violet = Color(red: 0.486, green: 0.361, blue: 1.0)
private let amber = Color(red: 0.910, green: 0.706, blue: 0.353)

/// Two 2-pt bars, 44 pt wide: 5 hours on top, the week below; a month-only
/// account gets the single bar. Nothing is drawn for a reading that is not `.read`.
struct CapacityHairlines: View {
    let reading: CapacityReading?
    let now: Date

    var body: some View {
        if let reading, reading.state == .read {
            VStack(spacing: 3) {
                if let month = reading.month, reading.fiveHour == nil {
                    bar(month)
                } else {
                    bar(reading.fiveHour)
                    bar(reading.sevenDay)
                }
            }
            .frame(width: 44)
            // Static text, so the reading surfaces in the ACCOUNT cell's own
            // text the way a Text does (measured: a bare labelled element
            // did not reach the window's tree).
            .accessibilityElement()
            .accessibilityLabel(CapacityDisplay.paletteText(reading, now: now).text)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier("capacity.hairlines")
        }
    }

    @ViewBuilder private func bar(_ w: CapacityWindow?) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(violet.opacity(0.18))
            if let w {
                if CapacityDisplay.hasReset(w, now: now) {
                    Capsule().strokeBorder(violet.opacity(0.5), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                } else {
                    GeometryReader { g in
                        Capsule().fill(CapacityDisplay.isLow(w) ? amber : violet.opacity(0.85))
                            .frame(width: g.size.width * CGFloat(w.percentLeft) / 100)
                    }
                }
            }
        }
        .frame(height: 2)
    }
}

/// The card every capacity indicator opens: every provider in the org.
struct CapacityHoverCard: View {
    let organisation: String
    let readings: [CapacityReading]
    let inUse: String
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("CAPACITY · \(organisation.uppercased())")
                Spacer()
                Text("LEFT")
            }
            .font(.system(size: 8.5, weight: .medium)).tracking(1.6)
            .foregroundStyle(Color.white.opacity(0.5))
            CapacityRows(readings: readings, inUse: inUse, now: now)
        }
        .padding(12)
        .frame(width: 272)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.055, green: 0.063, blue: 0.098)))   // §2 slab #0e1019
        .shadow(color: .black.opacity(0.55), radius: 18, y: 8)
        .accessibilityIdentifier("capacity.card")
    }
}
