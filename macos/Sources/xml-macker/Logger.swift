import Foundation

// Tiny, reliable diagnostic logger: a timestamp and a message appended
// to a file, so where the time goes can be read back without Xcode or
// Console.app.
//
// The log lives in the user's own Library, NOT in /tmp. It records the
// names of elements and the paths of files, which belong to whoever is
// using the app: /tmp is shared by every account on the machine and
// world readable, so anyone logged in could have read them. /tmp is
// also world WRITABLE, so a fixed name there can be pre-made as a
// symlink by someone else and the writes follow it somewhere unwanted.
// A file the app creates inside its own folder, readable only by its
// owner, has neither problem.
enum Diag {
    /// ~/Library/Logs/xml-macker/xml-macker.log, created 0600.
    private static let url: URL? = {
        guard let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Logs/xml-macker", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(
            at: logs, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return logs.appendingPathComponent("xml-macker.log")
    }()

    /// Where to tell the user their log is, when something goes wrong.
    static var displayPath: String { url?.path ?? "the app's Logs folder" }

    private static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let queue = DispatchQueue(label: "xml-macker.diag")

    static func log(_ msg: @autoclosure @escaping () -> String) {
        let message = msg()
        let line = "[\(fmt.string(from: Date()))] \(message)\n"
        queue.async {
            guard let url, let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) {
                if let h = try? FileHandle(forWritingTo: url) {
                    defer { try? h.close() }
                    _ = try? h.seekToEnd()
                    try? h.write(contentsOf: data)
                }
            } else {
                fm.createFile(atPath: url.path, contents: data,
                              attributes: [.posixPermissions: 0o600])
            }
        }
    }

    @discardableResult
    static func time<T>(_ name: String, _ block: () -> T) -> T {
        let t0 = Date()
        let r = block()
        let dt = Date().timeIntervalSince(t0)
        log("\(name): \(String(format: "%.3f", dt))s")
        return r
    }
}
