import AppKit

/// Paints every match of `tokens` in the system's own find-highlight yellow.
/// The font and base colour have to be baked in: a text field ignores its own
/// `font`/`textColor` once it is handed an attributed string.
func highlighted(
    _ text: String,
    tokens: [SearchToken],
    font: NSFont,
    color: NSColor
) -> NSAttributedString {
    let result = NSMutableAttributedString(
        string: text,
        attributes: [.font: font, .foregroundColor: color]
    )
    for range in SearchQuery.ranges(of: tokens, in: text) {
        result.addAttributes(
            // `findHighlightColor` is a fixed yellow in both appearances, so the
            // text on top of it has to be fixed black rather than `labelColor`.
            [.backgroundColor: NSColor.findHighlightColor, .foregroundColor: NSColor.black],
            range: NSRange(range, in: text)
        )
    }
    return result
}

extension NSTextField {
    /// Sets plain text, or highlighted text when there is a query to highlight.
    func setText(_ text: String, tokens: [SearchToken], font: NSFont, color: NSColor) {
        self.font = font
        if tokens.isEmpty {
            stringValue = text
            textColor = color
        } else {
            attributedStringValue = highlighted(text, tokens: tokens, font: font, color: color)
        }
    }
}

enum DateFormat {
    /// "Apr 23, 2026 at 23:48" — matches the Gitbox display style.
    static let commitTimestamp: Date.FormatStyle = {
        Date.FormatStyle()
            .month(.abbreviated)
            .day(.defaultDigits)
            .year(.defaultDigits)
            .hour(.defaultDigits(amPM: .omitted))
            .minute(.twoDigits)
            .locale(.current)
    }()

    /// "April 23, 2026 at 11:38:13PM PDT" — fuller form for the right-pane detail header.
    static let commitDetailTimestamp: Date.FormatStyle = {
        Date.FormatStyle()
            .month(.wide)
            .day(.defaultDigits)
            .year(.defaultDigits)
            .hour(.defaultDigits(amPM: .abbreviated))
            .minute(.twoDigits)
            .second(.twoDigits)
            .timeZone(.specificName(.short))
            .locale(.current)
    }()
}
