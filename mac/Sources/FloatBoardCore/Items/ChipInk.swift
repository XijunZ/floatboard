import Foundation

/// The text colour of a tag chip in light mode (round 9). A tag colour that is too light to read on the near-white chip
/// (contrast under 3:1 on white: yellow, cyan, green, orange) is darkened, keeping its hue, until it reaches 4.5:1; every
/// other colour is used as it is, so the board's chips look the same for them. Dark mode uses the colour unchanged.
public enum ChipInk {
    public static func lightModeHex(_ hex: String) -> String {
        guard let rgb = parse(hex), contrast(rgb) < 3 else { return hex }
        var f = 1.0
        var out = rgb
        while contrast(out) < 4.5 && f > 0.05 {
            f -= 0.02
            out = rgb.map { $0 * f }
        }
        return String(format: "#%02X%02X%02X", Int((out[0] * 255).rounded()), Int((out[1] * 255).rounded()), Int((out[2] * 255).rounded()))
    }

    /// WCAG contrast ratio of the colour against white.
    public static func contrastOnWhite(_ hex: String) -> Double { parse(hex).map(contrast) ?? 1 }

    /// The colour's hue in whole degrees (for checks).
    public static func hue(_ hex: String) -> Int {
        guard let c = parse(hex) else { return 0 }
        let mx = c.max()!, mn = c.min()!, d = mx - mn
        guard d > 0 else { return 0 }
        var h: Double
        if mx == c[0] { h = (c[1] - c[2]) / d } else if mx == c[1] { h = (c[2] - c[0]) / d + 2 } else { h = (c[0] - c[1]) / d + 4 }
        h *= 60
        if h < 0 { h += 360 }
        return Int(h.rounded())
    }

    static func parse(_ hex: String) -> [Double]? {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6, let v = UInt64(h, radix: 16) else { return nil }
        return [Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255]
    }

    static func contrast(_ c: [Double]) -> Double {
        let l = c.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        let lum = 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2]
        return 1.05 / (lum + 0.05)
    }
}
