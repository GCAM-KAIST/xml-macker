import Foundation

// The app has carried four earlier names; each rename changed the bundle
// identifier and therefore the UserDefaults domain. Carry the user's
// settings across once (theme, zoom, workspace, layout, window frames,
// toolbar), together with the folders the app owns outside UserDefaults
// (the marker's saved strokes and the Learn pane's logins), so a rename
// is invisible to them. The old names are spelled in halves so a
// project-wide rename can never touch them again.
enum LegacyDefaults {
    // NEWEST FIRST. The copy below is first-wins, and all four old
    // domains still exist on disk with keys that collide once rewritten
    // (every "...Popout-Chart" frame, every toolbar config). Appending
    // instead of prepending would hand the user his oldest layout back.
    private static let hops: [(domain: String, keyPrefix: String, framePrefix: String)] = [
        ("com.ahmed.xml" + "editorx", "XML" + "EDITORX.", "XML" + "EDITORX"),
        ("com.ahmed.xml" + "readerx", "XML" + "READERX.", "XML" + "READERX"),
        ("com.ahmed.xml" + "marker",  "XML" + "Marker.",  "XML" + "Macker"),
        ("com.ahmed.xml" + "macker",  "XML" + "MACker.",  "XML" + "Macker"),
    ]
    private static let doneKey = "xml-macker.migratedLegacyDefaults.v4"

    /// Mark the migration as already done without running it. Reset All
    /// Settings has to call this: wiping the domain also wipes the flag,
    /// so without it the next launch re-imports the old settings and the
    /// "fresh start" quietly undoes itself.
    static func markMigrated() { UserDefaults.standard.set(true, forKey: doneKey) }

    /// Folders the app owns outside UserDefaults, carried across the same
    /// rename. Settings alone are not the whole of what a user would lose:
    /// the marker's saved strokes live in Application Support, and the
    /// Learn pane's logins live in WebKit's own store, which is keyed on
    /// the bundle identifier and so points somewhere empty after a rename.
    /// What one attempt at carrying a store came to.
    enum Carried: Equatable {
        case nothing        // there was nothing at the old place
        case done           // it arrived
        case failed         // there was something, and it did not arrive
    }

    /// Copies `from` to `to` when there is something to copy and nothing
    /// is already there. Copy rather than move: if this build is run
    /// beside an older one, the older app keeps working.
    ///
    /// The copy is staged under a `.incoming` name and only put in place
    /// once the whole tree has arrived. A half-copied folder carrying the
    /// final name would look finished to every later launch, and the one
    /// store that matters here is a browser profile of a thousand files
    /// in nested folders.
    @discardableResult
    static func carry(_ from: URL?, _ to: URL?) -> Carried {
        let fm = FileManager.default
        guard let from, let to, fm.fileExists(atPath: from.path) else { return .nothing }
        // An EMPTY folder at the destination does not count as "already
        // there": stores create their folder the first time they are
        // touched, which can happen before this runs. Only real content
        // at the destination is left alone.
        if fm.fileExists(atPath: to.path) {
            let entries = (try? fm.contentsOfDirectory(atPath: to.path)) ?? ["not a folder"]
            guard entries.isEmpty else { return .nothing }
            try? fm.removeItem(at: to)
        }
        let staging = to.deletingLastPathComponent()
            .appendingPathComponent(to.lastPathComponent + ".incoming")
        try? fm.removeItem(at: staging)                  // a previous attempt
        try? fm.createDirectory(at: to.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: from, to: staging)       // copyItem recurses
            try fm.moveItem(at: staging, to: to)         // in place, all at once
            return .done
        } catch {
            try? fm.removeItem(at: staging)              // never leave a part of a tree
            return .failed
        }
    }

    private static func migrateFolders() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        // This marker means "every folder store arrived". It is separate
        // from the settings flag on purpose: if a store cannot be copied
        // yet, because the previous build is still running and holding a
        // file, this must stay unwritten so the next launch tries again,
        // while the settings flag stays written so the reset behaviour
        // does not come back.
        let marker = support?.appendingPathComponent("xml-macker/.migrated-stores")
        if let marker, fm.fileExists(atPath: marker.path) { return }

        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first
        let current = Bundle.main.bundleIdentifier ?? "com.ahmed.xml" + "macker"
        var anyFailed = false

        func attempt(_ from: URL?, _ to: URL?) {
            if carry(from, to) == .failed { anyFailed = true }
        }

        for old in ["XML" + "EDITORX", "XML" + "READERX", "XML" + "Marker"] {
            attempt(support?.appendingPathComponent(old + "/highlights", isDirectory: true),
                    support?.appendingPathComponent("xml-macker/highlights", isDirectory: true))
        }
        for old in ["com.ahmed.xml" + "editorx", "com.ahmed.xml" + "readerx", "com.ahmed.xml" + "marker"] {
            guard old != current else { continue }
            attempt(library?.appendingPathComponent("WebKit/" + old, isDirectory: true),
                    library?.appendingPathComponent("WebKit/" + current, isDirectory: true))
            attempt(library?.appendingPathComponent("HTTPStorages/" + old + ".binarycookies"),
                    library?.appendingPathComponent("HTTPStorages/" + current + ".binarycookies"))
        }

        // Only when nothing was left behind. Otherwise the next launch,
        // with the old build closed, gets another go.
        guard !anyFailed, let marker else { return }
        try? fm.createDirectory(at: marker.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        fm.createFile(atPath: marker.path, contents: Data())
    }

    static func migrateIfNeeded() {
        migrateFolders()                 // guarded by its own marker file
        let d = UserDefaults.standard
        guard !d.bool(forKey: doneKey) else { return }
        for hop in hops {
            guard let old = d.persistentDomain(forName: hop.domain), !old.isEmpty else { continue }
            for (key, value) in old {
                let newKey = key
                    .replacingOccurrences(of: hop.keyPrefix, with: "xml-macker.")
                    .replacingOccurrences(of: hop.framePrefix, with: "xml-macker")
                if d.object(forKey: newKey) == nil { d.set(value, forKey: newKey) }
            }
        }
        d.set(true, forKey: doneKey)
    }
}
