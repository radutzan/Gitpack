import AppKit

/// An `NSTableView` that offers unmodified keypresses to a handler before
/// AppKit turns them into type-select. Gitbox's bare-key shortcuts (`u`/`p` in
/// history, `s`/`d` in the file lists) live here; returning `false` falls
/// through to the normal behaviour.
final class KeyTableView: NSTableView {
    var onBareKey: ((String) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let bare = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
        if bare, let key = event.charactersIgnoringModifiers, onBareKey?(key) == true {
            return
        }
        super.keyDown(with: event)
    }
}
