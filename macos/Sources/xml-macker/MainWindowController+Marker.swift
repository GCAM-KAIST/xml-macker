// MainWindowController+Marker.swift
//
// The marker pen, ported from the Windows edition.
//
// Turn it on and the pointer becomes a pen. Drag over words and exactly
// those words are marked in the current colour. A plain click marks the
// whole line. Dragging the same colour again erases. Escape, or the
// button, puts the pen away.
//
// Marks belong to the document, not to a line number, so they survive
// editing: TextHighlights.shiftForEdit is driven from the editor's single
// edit funnel.

import Cocoa

extension MainWindowController {

    static let markerColorKey = "xml-macker.markerColor"

    var markerColor: HighlightColor {
        get {
            HighlightColor(rawValue: UserDefaults.standard.object(forKey: Self.markerColorKey) as? Int ?? 3)
                ?? .yellow
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.markerColorKey) }
    }

    /// Wired once at start-up.
    func installMarker() {
        sourceVC.onMarkerStroke = { [weak self] range in self?.paintMarker(over: range) }
        sourceVC.onMarkerCancel = { [weak self] in self?.setMarker(false) }
    }

    /// The strokes of the tab in front, handed to the editor that draws them.
    func attachMarkerStrokes() {
        guard sessions.indices.contains(activeSessionIdx) else {
            sourceVC.markerStrokes = nil
            popSource?.markerStrokes = nil
            return
        }
        let strokes = sessions[activeSessionIdx].highlights
        strokes.onChanged = { [weak self] in
            self?.sourceVC.redrawMarker()
            self?.popSource?.redrawMarker()
            self?.minimap.markerStrokes = strokes
        }
        sourceVC.markerStrokes = strokes
        popSource?.markerStrokes = strokes
        minimap.markerStrokes = strokes
    }

    /// Keeps the drawn pointer in step with the chosen colour.
    private func pushMarkerCursorColor() {
        let c = markerColor == .none ? XMColor.text2 : XMColor.marker(markerColor).withAlphaComponent(1)
        sourceVC.markerCursorColor = c
        popSource?.markerCursorColor = c
    }

    func setMarker(_ on: Bool) {
        pushMarkerCursorColor()
        guard sessions.indices.contains(activeSessionIdx) || !on else {
            NSSound.beep()
            statusLabel.stringValue = "Open a file first"
            return
        }
        sourceVC.markerOn = on
        popSource?.markerOn = on
        markerButton?.state = on ? .on : .off
        statusLabel.stringValue = on
            ? "Marker on, \(markerColor.label.lowercased()): drag over words to mark them, Escape to stop"
            : "Marker off"
    }

    @objc func toggleMarker(_ sender: Any?) { setMarker(!sourceVC.markerOn) }

    /// The toolbar button: a plain click takes the pen or puts it away, a
    /// right-click or an option-click opens the colours.
    @objc func tbMarker(_ sender: Any?) {
        let e = NSApp.currentEvent
        if let b = sender as? NSView,
           e?.type == .rightMouseUp || e?.modifierFlags.contains(.option) == true {
            showMarkerMenu(b)
            return
        }
        toggleMarker(sender)
    }

    /// Paints what the user just dragged, or the whole line for a plain
    /// click. Dragging the same colour again erases.
    private func paintMarker(over range: NSRange) {
        guard let strokes = sourceVC.markerStrokes else { return }
        var target = range
        if target.length == 0 {
            target = sourceVC.lineCharRange(containing: target.location)
            // Do not carry the newline into the stroke.
            if target.length > 0 { target.length -= 1 }
        }
        guard target.length > 0 else { return }
        let colour = markerColor
        let line = sourceVC.lineNumber(forOffset: target.location)
        if colour != .none, strokes.isCovered(start: target.location, length: target.length, color: colour) {
            strokes.paint(start: target.location, length: target.length, color: .none)
            statusLabel.stringValue = "Mark removed, line \(line), \(markCountNote(strokes))"
        } else {
            strokes.paint(start: target.location, length: target.length, color: colour)
            statusLabel.stringValue = colour == .none
                ? "Mark removed, line \(line), \(markCountNote(strokes))"
                : "Marked in \(colour.label.lowercased()), line \(line), \(markCountNote(strokes))"
        }
        saveHighlights()
    }

    private func markCountNote(_ strokes: TextHighlights) -> String {
        "\(strokes.count) mark\(strokes.count == 1 ? "" : "s") in this file"
    }

    /// Marks the selection, or the line the caret is on, without taking
    /// the pen out. The same gesture as on Windows.
    @objc func markNow(_ sender: Any?) {
        guard sourceVC.markerStrokes != nil else {
            NSSound.beep()
            statusLabel.stringValue = "Open a file first"
            return
        }
        paintMarker(over: sourceVC.exposedTextView.selectedRange())
    }

    @objc func chooseMarkerColor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
              let c = HighlightColor(rawValue: raw) else { return }
        markerColor = c
        markerButton?.contentTintColor = c == .none ? XMColor.text2 : XMColor.marker(c).withAlphaComponent(1)
        pushMarkerCursorColor()
        setMarker(true)          // picking a colour reaches for the pen
    }

    @objc func removeAllMarks(_ sender: Any?) {
        sourceVC.markerStrokes?.clear()
        saveHighlights()
        statusLabel.stringValue = "All marks removed"
    }

    /// The chevron beside the pen: the colours, the eraser, marking
    /// without the pen, walking the marks, and Remove All Marks.
    @objc func tbMarkerMenu(_ sender: Any?) {
        guard let view = sender as? NSView else { return }
        showMarkerMenu(view)
    }

    /// The toolbar chevron: forwards, or backwards with Shift held.
    @objc func tbMarkerJump(_ sender: Any?) {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            jumpToPreviousMark(sender)
        } else {
            jumpToNextMark(sender)
        }
    }

    /// Walks the marks, wrapping at the end.
    @objc func jumpToNextMark(_ sender: Any?) {
        guard let strokes = sourceVC.markerStrokes, !strokes.isEmpty else {
            NSSound.beep()
            statusLabel.stringValue = "Nothing is marked yet"
            return
        }
        let here = sourceVC.exposedTextView.selectedRange().location
        guard let r = strokes.next(after: here) else { return }
        sourceVC.revealMatch(NSRange(location: r.start, length: r.length))
        statusLabel.stringValue = "Mark \(strokes.ordinal(of: r)) of \(strokes.count)"
    }

    @objc func jumpToPreviousMark(_ sender: Any?) {
        guard let strokes = sourceVC.markerStrokes, !strokes.isEmpty else {
            NSSound.beep()
            statusLabel.stringValue = "Nothing is marked yet"
            return
        }
        let here = sourceVC.exposedTextView.selectedRange().location
        guard let r = strokes.previous(before: here) else { return }
        sourceVC.revealMatch(NSRange(location: r.start, length: r.length))
        statusLabel.stringValue = "Mark \(strokes.ordinal(of: r)) of \(strokes.count)"
    }

    /// The colour menu, shown from the button and from Edit ▸ Marker.
    func buildMarkerMenu() -> NSMenu {
        let m = NSMenu()
        let toggle = NSMenuItem(title: sourceVC.markerOn ? "Put the Marker Away" : "Take the Marker",
                                action: #selector(toggleMarker(_:)), keyEquivalent: "")
        toggle.target = self
        m.addItem(toggle)
        m.addItem(.separator())
        for c in [HighlightColor.yellow, .green, .blue, .red] {
            let item = NSMenuItem(title: c.label, action: #selector(chooseMarkerColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = c.rawValue
            item.state = (c == markerColor) ? .on : .off
            m.addItem(item)
        }
        let eraser = NSMenuItem(title: "Eraser", action: #selector(chooseMarkerColor(_:)), keyEquivalent: "")
        eraser.target = self
        eraser.representedObject = HighlightColor.none.rawValue
        eraser.state = (markerColor == .none) ? .on : .off
        m.addItem(eraser)
        m.addItem(.separator())
        let now = NSMenuItem(title: "Mark the Selection or This Line Now",
                             action: #selector(markNow(_:)), keyEquivalent: "")
        now.target = self
        m.addItem(now)
        m.addItem(.separator())
        let next = NSMenuItem(title: "Go to Next Mark", action: #selector(jumpToNextMark(_:)), keyEquivalent: "")
        next.target = self
        m.addItem(next)
        let prev = NSMenuItem(title: "Go to Previous Mark", action: #selector(jumpToPreviousMark(_:)), keyEquivalent: "")
        prev.target = self
        m.addItem(prev)
        m.addItem(.separator())
        let clear = NSMenuItem(title: "Remove All Marks", action: #selector(removeAllMarks(_:)), keyEquivalent: "")
        clear.target = self
        m.addItem(clear)
        return m
    }

    @objc func showMarkerMenu(_ sender: NSView) {
        buildMarkerMenu().popUp(positioning: nil,
                                at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    // MARK: remembering marks per file

    func saveHighlights() {
        guard sessions.indices.contains(activeSessionIdx) else { return }
        let s = sessions[activeSessionIdx]
        guard !s.isUntitled else { return }
        HighlightStore.save(s.highlights, for: s.url, text: sourceVC.documentText)
    }

    func loadHighlights(for session: DocumentSession, text: String) {
        guard !session.isUntitled else { return }
        HighlightStore.load(into: session.highlights, for: session.url, text: text)
    }
}
