import Cocoa

// `--self-check` runs the built-in test harness against the exact code
// that ships and exits, without ever putting a window on screen. See
// SelfCheck.swift for why the harness lives in the app rather than in
// Tests/.
if CommandLine.arguments.contains("--self-check") {
    exit(SelfCheck.run())
}
// `--diff-check a.xml b.xml` compares two real files with both engines
// and prints the numbers, no window.
if let i = CommandLine.arguments.firstIndex(of: "--diff-check"),
   CommandLine.arguments.count > i + 2 {
    exit(SelfCheck.diffCheck(CommandLine.arguments[i + 1], CommandLine.arguments[i + 2]))
}

// `--chart-check file.xml <element> [key] [variable]` says what the quick
// chart would draw for one element of a real file, no window.
if let i = CommandLine.arguments.firstIndex(of: "--chart-check"),
   CommandLine.arguments.count > i + 2 {
    let args = CommandLine.arguments
    exit(SelfCheck.chartCheck(args[i + 1], args[i + 2],
                              args.count > i + 3 ? args[i + 3] : nil,
                              args.count > i + 4 ? args[i + 4] : nil))
}

// An application-wide net. AppKit already keeps the app alive when an
// exception is thrown inside the run loop, but it says nothing and
// records nothing, so a report of "it went strange" has no evidence
// behind it. This writes the reason and the call stack to the diagnostic
// log and tells the user in one line.
NSSetUncaughtExceptionHandler { exception in
    let reason = exception.reason ?? "no reason given"
    Diag.log("UNCAUGHT \(exception.name.rawValue): \(reason)")
    for frame in exception.callStackSymbols.prefix(24) { Diag.log("    \(frame)") }
    DispatchQueue.main.async {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Something went wrong"
        a.informativeText = "\(reason)\n\nThe app is still running. The details were written to /tmp/xmleditorx.log."
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
