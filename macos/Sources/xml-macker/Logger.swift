import Foundation

// Tiny, reliable diagnostic logger, appends a timestamp + message to
// /tmp/xmleditorx.log every call. Used to diagnose where time goes on
// operations like tree selection or layout pre-warming without needing
// Xcode / the Console.app.
enum Diag {
    private static let path = "/tmp/xmleditorx.log"
    private static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let queue = DispatchQueue(label: "xmleditorx.diag")

    static func log(_ msg: @autoclosure @escaping () -> String) {
        let message = msg()
        let line = "[\(fmt.string(from: Date()))] \(message)\n"
        queue.async {
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: path) {
                    if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                        defer { try? h.close() }
                        _ = try? h.seekToEnd()
                        try? h.write(contentsOf: data)
                    }
                } else {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
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
