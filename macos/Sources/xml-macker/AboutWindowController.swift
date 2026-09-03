import Cocoa

// About panel (v1.0), laid out like the developer's other apps: icon,
// name and version, developer, group, GitHub link, license, OK. The
// license line is prepared ahead of the actual release choice.
final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()
    static let githubURL = URL(string: "https://github.com/GCAM-KAIST")!

    private init() {
        let win = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let name = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "xml-macker"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        win.title = "About \(name)"
        win.isReleasedWhenClosed = false
        // Follow the chosen theme; without this the panel kept the system
        // appearance and could show light chrome under a dark theme.
        win.appearance = ThemeManager.current.appearance
        win.backgroundColor = XMColor.bg
        super.init(window: win)

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: "\(name)  v\(version)")
        title.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        title.alignment = .center
        let developer = NSTextField(labelWithString: "Developed by Ahmed SM Sobhy")
        developer.font = NSFont.systemFont(ofSize: 13)
        developer.alignment = .center
        let group = NSTextField(labelWithString: "KAIST IAM GROUP")
        group.font = NSFont.systemFont(ofSize: 13)
        group.alignment = .center
        let link = NSButton(title: "github.com/GCAM-KAIST", target: self, action: #selector(openLink(_:)))
        link.isBordered = false
        link.attributedTitle = NSAttributedString(string: "github.com/GCAM-KAIST", attributes: [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .font: NSFont.systemFont(ofSize: 13)])
        let license = NSTextField(labelWithString: "MIT license")
        license.font = NSFont.systemFont(ofSize: 12)
        license.textColor = .secondaryLabelColor
        license.alignment = .center
        let ok = NSButton(title: "OK", target: self, action: #selector(dismiss(_:)))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"

        let stack = NSStackView(views: [icon, title, developer, group, link, license, ok])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(18, after: icon)
        stack.setCustomSpacing(16, after: title)
        stack.setCustomSpacing(18, after: license)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 112),
            icon.heightAnchor.constraint(equalToConstant: 112),
            ok.widthAnchor.constraint(equalToConstant: 160),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
        win.contentView = content
        win.setContentSize(content.fittingSize)
    }
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openLink(_ sender: Any?) { NSWorkspace.shared.open(Self.githubURL) }
    @objc private func dismiss(_ sender: Any?) { window?.close() }
}
