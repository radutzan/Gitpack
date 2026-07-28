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

    // Kept so `backgroundStyle` can swap them out and back. NSTableCellView
    // recolors its own `textField`/`imageView` outlets automatically, but not
    // custom subviews — without this, selected rows draw dark text on the
    // accent-coloured highlight.
    private var titleColor: NSColor = .labelColor
    private var timestampColor: NSColor = .controlAccentColor

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

        for subview in [dot, title, timestamp, subtitle] {
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

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),
        ])
    }

    func configure(commit: Commit, marker: CommitMarker) {
        // Unmerged (other-branch-only) commits render italic and faded, like
        // Gitbox; merge commits keep their existing de-emphasis.
        let deemphasized = commit.isMerge || marker == .unmerged

        title.stringValue = commit.authorName
        title.font = deemphasized ? RowFont.italic : RowFont.semibold
        titleColor = deemphasized ? .secondaryLabelColor : .labelColor

        timestamp.stringValue = DateFormat.commitTimestamp.format(commit.date)
        timestamp.font = deemphasized ? RowFont.italic : RowFont.body
        timestampColor = deemphasized
            ? NSColor.controlAccentColor.withAlphaComponent(0.7)
            : .controlAccentColor
        timestamp.isHidden = false

        subtitle.stringValue = commit.subject.isEmpty ? " " : commit.subject
        subtitle.font = deemphasized ? RowFont.italic : RowFont.body

        dot.isHidden = marker == .none
        dot.layer?.backgroundColor = markerColor(marker).cgColor
        dot.toolTip = markerHelp(marker)

        applyColors()
    }

    func configureWorkingCopy(title text: String, subtitle subtitleText: String, dirty: Bool) {
        title.stringValue = text
        title.font = dirty ? RowFont.semibold : RowFont.body
        titleColor = dirty ? .labelColor : .secondaryLabelColor

        timestamp.stringValue = ""
        timestamp.isHidden = true

        subtitle.stringValue = subtitleText
        subtitle.font = RowFont.body

        dot.isHidden = true
        dot.toolTip = nil

        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        title.textColor = selected ? .alternateSelectedControlTextColor : titleColor
        timestamp.textColor = selected ? .alternateSelectedControlTextColor : timestampColor
        subtitle.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
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
