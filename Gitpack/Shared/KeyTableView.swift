import AppKit
import Quartz

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
final class KeyTableView: NSTableView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var onBareKey: ((String) -> Bool)?
    /// Files to Quick Look for the current selection. Set it and Space toggles
    /// the preview panel, the way it does in Finder.
    var quickLookURLs: (() -> [URL])?

    override func keyDown(with event: NSEvent) {
        if consumed(event, by: { [unowned self] in
            $0 == " " && quickLookURLs != nil ? toggleQuickLook() : onBareKey?($0) == true
        }) { return }
        super.keyDown(with: event)
    }

    // MARK: Quick Look

    private var previewItems: [URL] = []
    private var selectionObserver: NSObjectProtocol?

    private func toggleQuickLook() -> Bool {
        let panel = QLPreviewPanel.shared()!
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else if quickLookURLs?().isEmpty == false {
            panel.makeKeyAndOrderFront(nil)
        }
        return true
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { quickLookURLs != nil }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        previewItems = quickLookURLs?() ?? []
        // Arrowing through the list while the panel is open follows the selection.
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTableView.selectionDidChangeNotification, object: self, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.previewItems = self.quickLookURLs?() ?? []
                panel.reloadData()
            }
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        selectionObserver.map(NotificationCenter.default.removeObserver)
        selectionObserver = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewItems[index] as NSURL
    }

    /// The panel is key while open; hand ↑/↓ (and Space, to close) back to the list.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Not ←/→: the panel pages through a multi-file preview with those,
        // and in the list they would move focus to another pane.
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        guard event.type == .keyDown,
              [up, down, " "].contains(event.charactersIgnoringModifiers ?? "") else { return false }
        keyDown(with: event)
        return true
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
