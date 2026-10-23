import SwiftUI
import AsBuiltCore

enum Theme {
    /// Safety orange: readable on white and dark backgrounds, recognisable on a job site.
    static let accent = Color(red: 0.88, green: 0.33, blue: 0.0)
    static let accentSoft = Color(red: 0.88, green: 0.33, blue: 0.0).opacity(0.12)
    static let ok = Color(red: 0.08, green: 0.55, blue: 0.25)
    static let warn = Color(red: 0.80, green: 0.50, blue: 0.0)
    static let bad = Color(red: 0.75, green: 0.12, blue: 0.12)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let hairline = Color(uiColor: .separator)
    static let minTap: CGFloat = 56
    static let corner: CGFloat = 14
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

extension PlanLayer {
    var color: Color { Color(hex: hexColor) }
    var uiColor: UIColor {
        let s = hexColor.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var legendName: String {
        switch self {
        case .walls: return "Walls"
        case .doors: return "Doors"
        case .windows: return "Windows"
        case .openings: return "Openings"
        case .fixtures: return "Fixtures"
        case .dimensions: return "Dimensions"
        case .text: return "Text"
        }
    }
}

/// Large, high-contrast primary action (gloves-friendly 56pt minimum height).
struct BigButtonStyle: ButtonStyle {
    var filled = true
    var color: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: Theme.minTap)
            .padding(.horizontal, 12)
            .foregroundStyle(filled ? Color.white : color)
            .background(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .fill(filled ? color : color.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .stroke(color, lineWidth: filled ? 0 : 2)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.hairline.opacity(0.5), lineWidth: 0.5))
    }
}

extension View {
    func card() -> some View { modifier(CardModifier()) }
}

struct SectionHeader: View {
    let title: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(Theme.accent)
            }
            Text(title.uppercased())
                .font(.footnote.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

struct Badge: View {
    let text: String
    var color: Color = Theme.accent

    var body: some View {
        Text(text)
            .font(.caption2.weight(.heavy))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(.white)
            .background(Capsule().fill(color))
    }
}

/// Value tile used on summaries ("168.0 sq ft / Floor area").
struct StatTile: View {
    let value: String
    let label: String
    var systemImage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.caption).foregroundStyle(Theme.accent) }
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.hairline.opacity(0.5), lineWidth: 0.5))
    }
}

/// Reads unit and estimating preferences shared by every screen.
enum Preferences {
    static let unitsKey = "units"
    static let wasteKey = "wastePercent"
    static let coatsKey = "paintCoats"

    static var units: UnitSystem {
        UnitSystem(rawValue: UserDefaults.standard.string(forKey: unitsKey) ?? "") ?? .imperial
    }

    static var takeoffOptions: TakeoffOptions {
        options(wastePercent: UserDefaults.standard.object(forKey: wasteKey) == nil ? 10 : UserDefaults.standard.double(forKey: wasteKey),
                coats: UserDefaults.standard.object(forKey: coatsKey) == nil ? 2 : UserDefaults.standard.integer(forKey: coatsKey))
    }

    static func options(wastePercent: Double, coats: Int) -> TakeoffOptions {
        TakeoffOptions(wasteFactor: max(0, wastePercent) / 100, paintCoats: max(1, coats))
    }
}
