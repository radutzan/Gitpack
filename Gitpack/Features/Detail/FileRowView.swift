import AppKit

/// Single, shared file-row layout used by both the working-copy and commit
/// detail panes. Same row height regardless of whether the trailing checkbox is
/// present; selection styling comes from the enclosing table.
final class FileRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FileRow")

    /// Fired by the checkbox. Nil-stage rows (commit detail) never call it.
    var onToggle: (() -> Void)?

    private let icon = NSImageView()
    private let pathField = NSTextField(labelWithString: "")
    private let statusField = NSTextField(labelWithString: "")
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FileRowView is created in code")
    }

    private func build() {
        icon.contentTintColor = .secondaryLabelColor

        pathField.font = NSFont.preferredFont(forTextStyle: .body)
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.cell?.usesSingleLineMode = true
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusField.font = NSFont.preferredFont(forTextStyle: .callout)
        statusField.textColor = .secondaryLabelColor
        statusField.setContentHuggingPriority(.required, for: .horizontal)
        statusField.setContentCompressionResistancePriority(.required, for: .horizontal)

        checkbox.target = self
        checkbox.action = #selector(toggled)
        checkbox.setContentHuggingPriority(.required, for: .horizontal)

        for subview in [icon, pathField, statusField, checkbox] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),

            pathField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            pathField.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathField.trailingAnchor.constraint(lessThanOrEqualTo: statusField.leadingAnchor, constant: -8),

            statusField.trailingAnchor.constraint(equalTo: checkbox.leadingAnchor, constant: -8),
            statusField.centerYAnchor.constraint(equalTo: centerYAnchor),

            checkbox.trailingAnchor.constraint(equalTo: trailingAnchor),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// `staged` nil means a read-only row — the checkbox is hidden but keeps its
    /// width, so commit-detail rows line up with working-copy rows.
    func configure(path: String, oldPath: String?, statusLabel: String, staged: Bool?) {
        icon.image = NSImage(systemSymbolName: iconName(for: path), accessibilityDescription: nil)
        pathField.stringValue = displayPath(path: path, oldPath: oldPath)
        pathField.toolTip = pathField.stringValue
        statusField.stringValue = statusLabel
        checkbox.isHidden = staged == nil
        checkbox.state = staged == true ? .on : .off
        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        pathField.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        statusField.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        icon.contentTintColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }

    private func displayPath(path: String, oldPath: String?) -> String {
        if let oldPath, oldPath != path {
            return "\(oldPath) → \(path)"
        }
        return path
    }

    @objc private func toggled() {
        onToggle?()
    }
}

func iconName(for path: String) -> String {
    let ext = (path as NSString).pathExtension.lowercased()
    switch ext {
    case "swift": return "swift"
    case "md", "markdown": return "doc.text"
    case "json", "yaml", "yml", "plist", "toml": return "curlybraces"
    case "png", "jpg", "jpeg", "gif", "heic", "tiff", "svg": return "photo"
    case "pbxproj": return "hammer"
    default: return "doc"
    }
}
