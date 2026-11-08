import AppKit

private enum RowFont {
    static let body = NSFont.preferredFont(forTextStyle: .body)
    static let semibold = NSFont.systemFont(ofSize: body.pointSize, weight: .semibold)
    static let italic = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
    static let semiboldItalic = NSFontManager.shared.convert(semibold, toHaveTrait: .italicFontMask)
}

/// Two-line history row: marker dot, author and timestamp on the first line,
/// subject on the second. Also renders the working-copy pseudo-row, which is
/// the same shape with no dot and no timestamp.
final class CommitRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CommitRow")

    private let dot = NSView()
    private let title = NSTextField(labelWithString: "")
    private let timestamp = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let tagBadge = TagBadgeView()

    // Kept so `backgroundStyle` can swap them out and back. NSTableCellView
    // recolors its own `textField`/`imageView` outlets automatically, but not
    // custom subviews — without this, selected rows draw dark text on the
    // accent-coloured highlight.
    private var titleColor: NSColor = .labelColor
    private var subtitleColor: NSColor = .labelColor
    private var timestampColor: NSColor = .secondaryLabelColor

    // The text has to be re-applied whenever the selection changes, because a
    // highlighted row carries its colours inside its attributed string.
    private var titleText = ""
    private var titleFont = RowFont.semibold
    private var subtitleText = ""
    private var subtitleFont = RowFont.body
    private var tokens: [SearchToken] = []
    private var marker = CommitMarker.none

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CommitRowView is created in code")
    }

    private func build() {
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5

        for field in [title, timestamp, subtitle] {
            field.lineBreakMode = .byTruncatingTail
            field.cell?.usesSingleLineMode = true
        }
        // The subject gives way first; the timestamp keeps its full width.
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timestamp.setContentCompressionResistancePriority(.required, for: .horizontal)
        timestamp.setContentHuggingPriority(.required, for: .horizontal)

        // A stack, so hiding the badge on an untagged commit closes the gap
        // without a second set of constraints to toggle.
        let secondLine = NSStackView(views: [tagBadge, subtitle])
        secondLine.orientation = .horizontal
        secondLine.alignment = .centerY
        secondLine.spacing = 5

        for subview in [dot, title, timestamp, secondLine] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            dot.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            title.bottomAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: timestamp.leadingAnchor, constant: -8),

            timestamp.trailingAnchor.constraint(equalTo: trailingAnchor),
            timestamp.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),

            secondLine.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            secondLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            secondLine.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),
        ])
    }

    func configure(
        commit: Commit,
        marker: CommitMarker,
        tags: [String] = [],
        tokens: [SearchToken] = []
    ) {
        // Unmerged (other-branch-only) commits render italic and faded, like
        // Gitbox; merge commits keep their existing de-emphasis.
        let deemphasized = commit.isMerge || marker == .unmerged

        self.tokens = tokens
        titleFont = deemphasized ? RowFont.italic : RowFont.semibold
        titleText = commit.authorName
        titleColor = deemphasized ? .secondaryLabelColor : .labelColor

        timestamp.stringValue = DateFormat.commitTimestamp.format(commit.date)
        timestamp.font = deemphasized ? RowFont.italic : RowFont.body
        timestampColor = deemphasized ? .tertiaryLabelColor : .secondaryLabelColor
        timestamp.isHidden = false

        subtitleFont = deemphasized ? RowFont.italic : RowFont.body
        subtitleText = commit.subject.isEmpty ? " " : commit.subject
        subtitleColor = deemphasized ? .secondaryLabelColor : .labelColor

        tagBadge.text = tags.joined(separator: "  ")

        dot.isHidden = marker == .none
        dot.toolTip = markerHelp(marker)
        self.marker = marker

        applyColors()
    }

    func configureWorkingCopy(title text: String, subtitle subtitleText: String, dirty: Bool) {
        tokens = []
        tagBadge.text = ""
        titleText = text
        titleFont = dirty ? RowFont.semibold : RowFont.body
        titleColor = dirty ? .labelColor : .secondaryLabelColor

        timestamp.stringValue = ""
        timestamp.isHidden = true

        self.subtitleText = subtitleText
        subtitleFont = RowFont.body
        subtitleColor = .secondaryLabelColor

        dot.isHidden = true
        dot.toolTip = nil

        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    /// Layer-backed colours are resolved once and don't follow the appearance on
    /// their own — the dot and the badge both go stale on a light/dark switch
    /// without this.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        dot.layer?.backgroundColor = markerColor(marker).cgColor
        tagBadge.applyColors(selected: selected)
        title.setText(
            titleText, tokens: tokens, font: titleFont,
            color: selected ? .alternateSelectedControlTextColor : titleColor
        )
        subtitle.setText(
            subtitleText, tokens: tokens, font: subtitleFont,
            color: selected ? .alternateSelectedControlTextColor : subtitleColor
        )
        timestamp.textColor = selected ? .alternateSelectedControlTextColor : timestampColor
    }

    private func markerColor(_ marker: CommitMarker) -> NSColor {
        switch marker {
        case .none: .clear
        case .unpushed: .systemGreen
        case .unmerged: .systemBlue
        }
    }

    private func markerHelp(_ marker: CommitMarker) -> String? {
        switch marker {
        case .none: nil
        case .unpushed: "Not yet pushed to the other branch"
        case .unmerged: "On the other branch, not yet merged"
        }
    }
}

/// Tag names on a history row, as one capsule. Gitbox drew a badge per tag; one
/// badge holding them all keeps the row a fixed height, which the list depends on.
private final class TagBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            isHidden = newValue.isEmpty
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 3
        isHidden = true

        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TagBadgeView is created in code")
    }

    func applyColors(selected: Bool) {
        label.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        layer?.backgroundColor = (selected
            ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.25)
            : NSColor.quaternaryLabelColor).cgColor
    }
}

/// The trailing "Load more commits" row. Not selectable — clicking it pages.
final class LoadMoreRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("LoadMoreRow")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let label = NSTextField(labelWithString: "Load more commits")
        label.font = NSFont.preferredFont(forTextStyle: .callout)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LoadMoreRowView is created in code")
    }
}
