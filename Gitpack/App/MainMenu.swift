import AppKit

/// The menu bar, built in code (there is no nib).
///
/// Every Gitpack action is installed with `target: nil` so it travels the
/// responder chain and lands on whichever object is willing to validate it —
/// today `AppDelegate.validateMenuItem`, and from Phase E the focused pane's
/// view controller. That chain is what replaces SwiftUI's `.disabled(…)`
/// recomputation.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu(), title: "Gitpack"))
        main.addItem(submenu(fileMenu(), title: "File"))
        main.addItem(submenu(editMenu(), title: "Edit"))
        main.addItem(submenu(repositoryMenu(), title: "Repository"))
        main.addItem(submenu(stageMenu(), title: "Stage"))
        main.addItem(submenu(windowMenu(), title: "Window"))
        return main
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "About Gitpack", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Gitpack", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Gitpack", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Add Repository…", action: #selector(AppDelegate.addRepository(_:)), keyEquivalent: "o")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return menu
    }

    /// SwiftUI supplied these for free. Without them ⌘C/⌘V/⌘Z stop working in
    /// the commit composer, which is the one place this app has a text field.
    private static func editMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Find", action: #selector(AppDelegate.findInHistory(_:)), keyEquivalent: "f")
        return menu
    }

    private static func repositoryMenu() -> NSMenu {
        let menu = NSMenu()
        // Title flips to "Merge" in validateMenuItem when the other branch is
        // local. Bare-key `u`/`p` stay on the focused list (a bare key in the
        // menu bar would fire while you type a commit message).
        menu.addItem(withTitle: "Pull", action: #selector(AppDelegate.pullOrMerge(_:)), keyEquivalent: "u")
        menu.addItem(withTitle: "Push", action: #selector(AppDelegate.push(_:)), keyEquivalent: "p")
        let fetch = menu.addItem(withTitle: "Fetch", action: #selector(AppDelegate.fetch(_:)), keyEquivalent: "u")
        fetch.keyEquivalentModifierMask = [.command, .option]
        let rebase = menu.addItem(withTitle: "Rebase", action: #selector(AppDelegate.rebase(_:)), keyEquivalent: "u")
        rebase.keyEquivalentModifierMask = [.command, .shift]
        let forcePush = menu.addItem(withTitle: "Force Push", action: #selector(AppDelegate.forcePush(_:)), keyEquivalent: "p")
        forcePush.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        // Validated by whichever file list has focus (that's where the selected
        // path lives), so it greys out from anywhere else.
        menu.addItem(
            withTitle: "Show File History",
            action: #selector(CommitViewController.showFileHistory(_:)),
            keyEquivalent: "d"
        )
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open in Finder", action: #selector(AppDelegate.openInFinder(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Open in Terminal", action: #selector(AppDelegate.openInTerminal(_:)), keyEquivalent: "")
        return menu
    }

    private static func stageMenu() -> NSMenu {
        let menu = NSMenu()
        let stageAll = menu.addItem(withTitle: "Stage All", action: #selector(AppDelegate.stageAll(_:)), keyEquivalent: "\r")
        stageAll.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: "Commit", action: #selector(AppDelegate.commitChanges(_:)), keyEquivalent: "\r")
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        return menu
    }
}
