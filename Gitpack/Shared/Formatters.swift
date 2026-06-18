import Foundation

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
