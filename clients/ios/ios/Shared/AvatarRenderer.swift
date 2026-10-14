import UIKit

/// The sender's image for a communication notification (task 01a12773
/// stage 4; design canvas 01a12774). Always produces an image: a nil INPerson
/// image makes iOS draw its own grey initials, which the canvas forbids. The
/// system draws the circle and the app badge, so there is no ring or badge
/// here.
///
/// Built to the IN-APP renderer (`PlatformWeb.AvatarComponents`), matching
/// the Android `Monogram`:
/// - an agent (tone `agent`): ONE initial, primary on base-300, bold;
/// - a person (tone `0`..`7`): up to TWO initials in the `.avatar-fallback-N`
///   pair from app.css (oklch converted to sRGB), semibold;
/// - initials are the first grapheme (`Character`) of each
///   whitespace-separated word, upper-cased; no letters at all is `U`.
///
/// A fetched picture is drawn over an OPAQUE base-100 square, so a
/// transparent PNG never shows the notification's material through it.
enum AvatarRenderer {
    static let side: CGFloat = 192
    static let agentTone = "agent"

    struct Theme: Equatable {
        let base100: UInt32
        let base300: UInt32
        let primary: UInt32
    }

    static let light = Theme(base100: 0xFBFAF9, base300: 0xEFEBE7, primary: 0xAD4B07)
    static let dark = Theme(base100: 0x191B20, base300: 0x25272B, primary: 0xF47721)

    /// `.avatar-fallback-0..7` (background, text), app.css oklch as sRGB.
    static let fallbackPairs: [(background: UInt32, foreground: UInt32)] = [
        (0xFB979A, 0x572125),
        (0xF3B680, 0x542D00),
        (0xA5D086, 0x293F17),
        (0x80D1B5, 0x093F31),
        (0x73CFF1, 0x003F53),
        (0xAEB8FE, 0x30335C),
        (0xE3A9EB, 0x4B2850),
        (0xE8B5BA, 0x4A2F32),
    ]

    /// The theme iOS is showing (the notification follows the system style).
    static var currentTheme: Theme { UITraitCollection.current.userInterfaceStyle == .dark ? dark : light }

    static func isAgent(_ tone: String?) -> Bool { tone == agentTone }

    /// The in-app initials: the first grapheme of each of the first `count` words.
    static func initials(_ name: String?, count: Int) -> String {
        let words = (name ?? "").split(whereSeparator: { $0.isWhitespace })
        let text = words.prefix(count).compactMap { $0.first.map { String($0).uppercased() } }.joined()
        return text.isEmpty ? "U" : text
    }

    /// (background, text) for a tone. An unknown tone picks a stable pair from the name.
    static func colors(tone: String?, name: String?, theme: Theme) -> (background: UInt32, foreground: UInt32) {
        if isAgent(tone) { return (theme.base300, theme.primary) }
        if let index = tone.flatMap({ Int($0) }), fallbackPairs.indices.contains(index) { return fallbackPairs[index] }
        let seed = (name ?? "").unicodeScalars.reduce(UInt32(0)) { ($0 &* 31) &+ $1.value }
        return fallbackPairs[Int(seed % UInt32(fallbackPairs.count))]
    }

    static func color(_ rgb: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    private static func renderer() -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
    }

    /// The letter disc as PNG data: an opaque square in the tone's colour
    /// (the system crops it to a circle) with the initials centred.
    static func fallback(name: String?, tone: String?, theme: Theme = currentTheme) -> Data {
        let (background, foreground) = colors(tone: tone, name: name, theme: theme)
        let agent = isAgent(tone)
        let glyphs = initials(name, count: agent ? 1 : 2)
        return renderer().pngData { context in
            color(background).setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            var font = UIFont.systemFont(ofSize: side * 0.45, weight: agent ? .bold : .semibold)
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(foreground)]
            var size = (glyphs as NSString).size(withAttributes: attributes)
            let maxWidth = side * 0.72
            if size.width > maxWidth {
                font = font.withSize(font.pointSize * maxWidth / size.width)
                attributes[.font] = font
                size = (glyphs as NSString).size(withAttributes: attributes)
            }
            // Optically centred on the cap height, not the line box.
            let originY = (side - font.capHeight) / 2 - (font.ascender - font.capHeight)
            (glyphs as NSString).draw(at: CGPoint(x: (side - size.width) / 2, y: originY), withAttributes: attributes)
        }
    }

    /// A fetched picture, centre-cropped to a square over opaque base-100, as PNG; nil if it does not decode.
    static func flatten(_ imageData: Data, theme: Theme = currentTheme) -> Data? {
        guard let image = UIImage(data: imageData), image.size.width > 0, image.size.height > 0 else { return nil }
        return renderer().pngData { context in
            color(theme.base100).setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let scale = side / min(image.size.width, image.size.height)
            let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
    }

    /// The image to hand INPerson: the flattened picture, else the letter disc. Never nil.
    static func senderImage(name: String?, tone: String?, picture: Data?, theme: Theme = currentTheme) -> Data {
        picture.flatMap { flatten($0, theme: theme) } ?? fallback(name: name, tone: tone, theme: theme)
    }
}
