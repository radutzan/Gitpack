import AppKit

/// The two dialogs every repository operation needs. Modal `NSAlert`s rather
/// than sheets, so a menu action reads the answer inline instead of threading a
/// completion handler back through four layers of menu plumbing.
enum Prompt {
    struct Field {
        let placeholder: String
        var value: String = ""
    }

    private static let fieldWidth: CGFloat = 300
    private static let fieldHeight: CGFloat = 26

    /// True when the user chose `action` rather than Cancel.
    static func confirm(
        _ message: String,
        detail: String? = nil,
        action: String,
        destructive: Bool = true
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        if let detail { alert.informativeText = detail }
        alert.alertStyle = destructive ? .warning : .informational
        let confirmButton = alert.addButton(withTitle: action)
        confirmButton.hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Trimmed field values in order, or nil when cancelled. Every field left
    /// blank also reads as a cancel — nothing asked for here has a meaningful
    /// empty answer, so that saves each caller the same guard.
    static func text(
        _ message: String,
        detail: String? = nil,
        action: String = "OK",
        fields: [Field]
    ) -> [String]? {
        let alert = NSAlert()
        alert.messageText = message
        if let detail { alert.informativeText = detail }
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")

        let inputs = fields.map { field -> NSTextField in
            let input = NSTextField(string: field.value)
            input.placeholderString = field.placeholder
            // Explicit, because a stack view lays its arranged subviews out at
            // their intrinsic width — and an empty NSTextField's intrinsic width
            // is 2pt. Without this the prompt is a pair of hairlines.
            input.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
            return input
        }
        let stack = NSStackView(views: inputs)
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(
            x: 0, y: 0, width: Self.fieldWidth,
            height: CGFloat(inputs.count) * Self.fieldHeight + CGFloat(max(0, inputs.count - 1)) * 8
        )
        alert.accessoryView = stack

        alert.window.initialFirstResponder = inputs.first

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let values = inputs.map { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        return values.contains(where: { !$0.isEmpty }) ? values : nil
    }
}
