import Foundation

// The app has carried four earlier names; each rename changed the bundle
// identifier and therefore the UserDefaults domain. Carry the user's
// settings across once (theme, zoom, workspace, layout, window frames,
// toolbar) so a rename is invisible to them. The old names are spelled
// in halves so a project-wide rename can never touch them again.
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

    static func migrateIfNeeded() {
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
