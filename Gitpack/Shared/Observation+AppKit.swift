import Foundation
import Observation

/// Runs `body` now, then again every time any `@Observable` property it read
/// changes. This is the AppKit substitute for SwiftUI's automatic invalidation:
/// view controllers call it once in `viewDidLoad` and reload themselves from
/// inside the closure.
///
/// The re-arm goes through a `Task` because `withObservationTracking`'s
/// `onChange` fires *before* the mutation lands — reading the new value
/// synchronously there would read the old one.
///
/// ponytail: no cancellation handle. Every caller is an app-lifetime observer
/// (window title, toolbar, the three panes), so nothing needs to stop
/// observing. If a transient observer appears, return a token that flips a
/// `cancelled` flag checked before the re-arm.
@MainActor
func observeChanges(_ body: @escaping @MainActor () -> Void) {
    withObservationTracking {
        body()
    } onChange: {
        Task { @MainActor in
            observeChanges(body)
        }
    }
}
