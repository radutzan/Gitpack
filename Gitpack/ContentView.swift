import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppState.self) private var appState

    // Not NavigationSplitView (its NSSplitView bridge laid columns out 13k–23k
    // pt tall, blanking the window) and not HSplitView (it ignores idealWidth
    // and min/max pinning when placing dividers, so saved widths never
    // restored). A plain HStack with explicit drag-handle dividers owns the
    // widths outright: restore is an init read, persistence is a write on
    // drag end, nothing is negotiated with a framework layout solver.
    @State private var sidebarWidth = ContentView.savedWidth("sidebarWidth", default: 220, min: 180, max: 320)
    @State private var detailWidth = ContentView.savedWidth("detailWidth", default: 420, min: 320, max: 2000)
    @State private var sidebarDragBase: CGFloat?
    @State private var detailDragBase: CGFloat?

    private static func savedWidth(_ key: String, default def: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        let value = UserDefaults.standard.object(forKey: key) as? Double ?? Double(def)
        return CGFloat(value).clamped(to: min...max)
    }

    var body: some View {
        GeometryReader { geo in
            // History keeps at least 320; detail yields when the window shrinks.
            let maxDetail = max(320, geo.size.width - sidebarWidth - 320 - 18)
            let detail = detailWidth.clamped(to: 320...maxDetail)
            HStack(spacing: 0) {
                RepositorySidebar()
                    .frame(width: sidebarWidth)
                PaneDivider { translation in
                    let base = sidebarDragBase ?? sidebarWidth
                    sidebarDragBase = base
                    sidebarWidth = (base + translation).clamped(to: 180...320)
                } onEnd: {
                    sidebarDragBase = nil
                    UserDefaults.standard.set(Double(sidebarWidth), forKey: "sidebarWidth")
                }
                HistoryList()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                PaneDivider { translation in
                    let base = detailDragBase ?? detail
                    detailDragBase = base
                    detailWidth = (base - translation).clamped(to: 320...maxDetail)
                } onEnd: {
                    detailDragBase = nil
                    UserDefaults.standard.set(Double(detailWidth), forKey: "detailWidth")
                }
                DetailPane()
                    .frame(width: detail)
            }
        }
        .navigationTitle(windowTitle)
        .toolbar {
            MainToolbar()
        }
        .task(id: appState.selectedRepositoryID) {
            await loadSelected()
            // Watch the now-selected repo so on-disk changes reflect live.
            appState.startWatchingSelectedRepository()
        }
        .task {
            appState.startAutofetch()
            // Refresh when the app returns to the foreground, catching any
            // changes made while it was inactive.
            let activations = NotificationCenter.default.notifications(
                named: NSApplication.didBecomeActiveNotification
            )
            for await _ in activations {
                await appState.foregroundRefresh()
            }
        }
    }

    private var windowTitle: String {
        if let repo = appState.selectedRepository {
            let parent = repo.url.deletingLastPathComponent().lastPathComponent
            return parent.isEmpty ? repo.displayName : "\(repo.displayName) — \(parent)"
        }
        return "Gitpack"
    }

    private func loadSelected() async {
        guard let vm = appState.selectedViewModel else { return }
        await vm.refreshAll(using: appState.git)
    }
}

/// A vertical divider with a 9pt grab area and a resize cursor. Reports the
/// drag's total horizontal translation; the owner applies it to a captured
/// base width so the math is stateless per event.
private struct PaneDivider: View {
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    var body: some View {
        Divider()
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { onDrag($0.translation.width) }
                    .onEnded { _ in onEnd() }
            )
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
