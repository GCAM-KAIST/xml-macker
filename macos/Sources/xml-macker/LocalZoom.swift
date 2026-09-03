import Cocoa

/// A pane that can scale its own text. Every pane already had these
/// three; the protocol only gives the pop-out window a way to reach
/// them without knowing which pane it is hosting.
protocol PaneZoomable: AnyObject {
    func zoomIn()
    func zoomOut()
    func zoomReset()
}

extension TreeViewController: PaneZoomable {}
extension SourceViewController: PaneZoomable {}
extension SubtagsBarViewController: PaneZoomable {}
extension AttributesBarViewController: PaneZoomable {}
extension PreviewPaneViewController: PaneZoomable {}

/// Command + wheel, for one window at a time.
///
/// Zoom has two levels, as it has on Windows: the toolbar slider is the
/// zoom of the whole app, while Command with the wheel (or Command and
/// the +, - and 0 keys) changes only the window, or the pane, the
/// pointer is over. A wheel sends many small deltas, so they are added
/// up here and a step is taken each time the total passes the
/// threshold; that keeps one flick of a trackpad from jumping the text
/// several sizes at once.
final class WheelZoom {
    private var monitor: Any?
    private var accumulated: CGFloat = 0
    private static let threshold: CGFloat = 3

    /// Starts watching `window`. `onStep` is called with true to zoom
    /// in and false to zoom out, and with the event, so the caller can
    /// see where the pointer was.
    /// - Parameters:
    ///   - passThrough: return true for an event this window should not
    ///     take, so the view under the pointer keeps its own gesture (the
    ///     Learn pane's web view pinches its page, for instance).
    func install(in window: NSWindow?,
                 passThrough: ((NSEvent) -> Bool)? = nil,
                 onStep: @escaping (Bool, NSEvent) -> Void) {
        guard monitor == nil, window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self, weak window] event in
            guard let self, let window, event.window === window else { return event }
            if passThrough?(event) == true { return event }
            // Two gestures, one zoom: Command with the wheel, and the
            // pinch every Mac trackpad makes in a photo viewer. A pinch
            // needs no modifier, so it is not filtered on one.
            let dy: CGFloat
            if event.type == .magnify {
                dy = event.magnification * Self.threshold * 8
            } else {
                guard event.modifierFlags.contains(.command) else { return event }
                dy = event.scrollingDeltaY
            }
            guard dy != 0 else { return nil }
            // A direction change starts the count again, so a small
            // push back the other way is felt at once.
            if (dy > 0) != (self.accumulated > 0) { self.accumulated = 0 }
            self.accumulated += dy
            while abs(self.accumulated) >= Self.threshold {
                onStep(self.accumulated > 0, event)
                self.accumulated -= self.accumulated > 0 ? Self.threshold : -Self.threshold
            }
            return nil                       // never scrolls as well as zooms
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    deinit { stop() }
}
