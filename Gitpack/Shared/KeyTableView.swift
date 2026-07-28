import AppKit

/// Offers an unmodified keypress to a handler before AppKit interprets it.
/// Returns true when the handler consumed it.
private func consumed(_ event: NSEvent, by handler: ((String) -> Bool)?) -> Bool {
    // Not `deviceIndependentFlagsMask.isEmpty`: the arrow keys always carry
    // `.function` and `.numericPad`, so that test silently rejected every one
    // of them. Only the modifiers a user actually holds disqualify a key —
    // which also keeps ⇧← extending a selection rather than switching panes.
    let held: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    guard event.modifierFlags.intersection(held).isEmpty,
          let key = event.charactersIgnoringModifiers else { return false }
    return handler?(key) == true
}

/// An `NSTableView` that offers unmodified keypresses to a handler before
/// AppKit turns them into type-select. Gitbox's bare-key shortcuts (`u`/`p` in
/// history, `s`/`d` in the file lists) live here, as does ←/→ pane navigation;
/// returning `false` falls through to the normal behaviour.
final class KeyTableView: NSTableView {
    var onBareKey: ((String) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if consumed(event, by: onBareKey) { return }
        super.keyDown(with: event)
    }
}

/// The same hook for the sidebar. `NSOutlineView` claims ←/→ for collapse and
/// expand, so pane navigation has to be taken before `super` sees it.
final class KeyOutlineView: NSOutlineView {
    var onBareKey: ((String) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if consumed(event, by: onBareKey) { return }
        super.keyDown(with: event)
    }
}

extension NSViewController {
    /// ←/→ move keyboard focus across the three panes. Returns true when `key`
    /// was one of them, so callers can chain it into their bare-key handler.
    func movePaneFocus(for key: String) -> Bool {
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        guard key == left || key == right else { return false }
        guard let split = enclosingSplitViewController,
              let pane = paneRoot(in: split) else { return false }
        split.focusPane(adjacentTo: pane, offset: key == left ? -1 : 1)
        return true
    }

    private var enclosingSplitViewController: MainSplitViewController? {
        sequence(first: self, next: \.parent).first { $0 is MainSplitViewController }
            as? MainSplitViewController
    }

    /// The controller that is actually a split view item — a file list's parent
    /// is `DetailViewController`, not the split controller.
    private func paneRoot(in split: MainSplitViewController) -> NSViewController? {
        sequence(first: self, next: \.parent).first { $0.parent === split }
    }
}
