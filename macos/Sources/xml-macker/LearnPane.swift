import Cocoa
import WebKit

// LEARN mode's browser pane (v0.37.0). LEARN sits beside the edit,
// inspect and full modes: it keeps the tree and source and adds one
// long browser down the right side, so anything selected in the file
// can be explained without leaving the window.
//
// A real WebKit browser (Safari's engine) pinned to the four chat
// sites that work embedded (Gemini refuses Google login inside
// embedded browsers, so it's not offered here). The website data
// store is the persistent default, so logins survive relaunches.
//
// insertPrompt() TYPES the text into the site's chat box via
// JavaScript, without sending, so you can add your own words
// first. The exact input element differs per site and changes over
// time, so the script tries the common shapes (ProseMirror
// contenteditable, textarea) and we always park the text on the
// clipboard too: worst case the status bar says "press ⌘V".
final class LearnPaneViewController: NSViewController, WKNavigationDelegate {

    enum Chat: Int, CaseIterable {
        case chatgpt = 0, claude, perplexity, grok, deepseek, qwen, glm, kimi, manus
        var title: String {
            ["ChatGPT", "Claude", "Perplexity", "Grok",
             "DeepSeek", "Qwen", "GLM (Z.ai)", "Kimi", "Manus"][rawValue]
        }
        var home: URL {
            URL(string: [
                "https://chatgpt.com/",
                "https://claude.ai/new",
                "https://www.perplexity.ai/",
                "https://grok.com/",
                "https://chat.deepseek.com/",
                "https://chat.qwen.ai/",
                "https://chat.z.ai/",
                "https://www.kimi.com/",
                "https://manus.im/",
            ][rawValue])!
        }
    }
    static let chatKey = "xml-macker.learnChat"

    /// The site the Learn pane opens on, and the one the Share menu
    /// types an element into. Settings shows it as "Chat site".
    static var defaultChat: Chat {
        get { Chat(rawValue: UserDefaults.standard.integer(forKey: chatKey)) ?? .chatgpt }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: chatKey) }
    }

    private(set) var webView: WKWebView!
    private var picker: NSPopUpButton!
    private let titleLabel = NSTextField(labelWithString: "LEARN")

    var onStatus: ((String) -> Void)?
    // MainWindowController supplies the payloads (it owns selection +
    // tree state); nil = nothing usable selected (it already beeped).
    var requestSelectionPrompt: (() -> String?)?
    var requestElementPrompt: (() -> String?)?
    // The file in front: its own folder, for dragging the file into the
    // chat, and its whole text, for pasting it in.
    var requestFileURL: (() -> URL?)?
    var requestWholeFile: (() -> String?)?

    // A prompt waiting for the page to finish loading (used when the
    // Share menu routes here and the chat isn't loaded yet).
    private var pendingPrompt: String?

    private var currentChat: Chat {
        get { Chat(rawValue: UserDefaults.standard.integer(forKey: Self.chatKey)) ?? .chatgpt }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.chatKey) }
    }

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = XMFont.uiCaption
        titleLabel.textColor = XMColor.text3
        v.addSubview(titleLabel)

        // One dropdown instead of a row of segments, with a label
        // beside it.
        let pickerLabel = NSTextField(labelWithString: "Choose LLM:")
        pickerLabel.font = XMFont.uiSmall
        pickerLabel.textColor = XMColor.text2
        pickerLabel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(pickerLabel)

        picker = NSPopUpButton(frame: .zero, pullsDown: false)
        for chat in Chat.allCases { picker.addItem(withTitle: chat.title) }
        picker.selectItem(at: currentChat.rawValue)
        picker.target = self
        picker.action = #selector(chatChanged(_:))
        picker.controlSize = .small
        picker.font = XMFont.ui(11, .medium)
        picker.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(picker)

        func headerButton(_ title: String, _ action: Selector, tip: String) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.isBordered = false
            b.font = XMFont.ui(13, .semibold)
            b.contentTintColor = XMColor.text2
            b.toolTip = tip
            b.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(b)
            return b
        }
        // Essential browser controls: the pane started out with no
        // back, forward, refresh or zoom.
        let back    = headerButton("◀", #selector(backClicked),   tip: "Back")
        let forward = headerButton("▶", #selector(forwardClicked), tip: "Forward")
        let reload  = headerButton("⟳", #selector(reloadClicked), tip: "Reload the page")
        let zoomOut = headerButton("−", #selector(zoomOutClicked), tip: "Make the page smaller")
        let zoomIn  = headerButton("＋", #selector(zoomInClicked), tip: "Make the page bigger")

        let defineSel = NSButton(title: "✨ Selection", target: self, action: #selector(defineSelectionClicked))
        defineSel.bezelStyle = .rounded
        defineSel.controlSize = .small
        defineSel.toolTip = "Define the highlighted source text: it is typed into the chat, nothing is sent until you press Return"
        defineSel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(defineSel)

        let defineEl = NSButton(title: "✨ Element", target: self, action: #selector(defineElementClicked))
        defineEl.bezelStyle = .rounded
        defineEl.controlSize = .small
        defineEl.toolTip = "Define the selected tree element: its XML is typed into the chat"
        defineEl.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(defineEl)

        // These two are Learn-only: one opens the file's folder so the
        // file can be dragged into the chat, the other puts the whole
        // file on the clipboard so it can be pasted.
        let showFolder = NSButton(title: "📁 Folder", target: self, action: #selector(showFolderClicked))
        showFolder.bezelStyle = .rounded
        showFolder.controlSize = .small
        showFolder.toolTip = "Open the folder of the file in front, with the file selected, ready to drag into the chat"
        showFolder.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(showFolder)

        let copyAll = NSButton(title: "Copy", target: self, action: #selector(copyWholeFileClicked))
        copyAll.bezelStyle = .rounded
        copyAll.controlSize = .small
        copyAll.toolTip = "Copy every line of the file in the Source pane, then paste it into the chat"
        copyAll.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(copyAll)

        for b in [defineSel, defineEl, showFolder, copyAll] {
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // persistent, stay logged in
        webView = XMLDropForwardingWebView(frame: .zero, configuration: config)
        // A plain Safari user agent, some chat sites degrade or block
        // "unknown embedded" agents.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(webView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),

            pickerLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            pickerLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            picker.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            picker.leadingAnchor.constraint(equalTo: pickerLabel.trailingAnchor, constant: 4),
            picker.widthAnchor.constraint(lessThanOrEqualToConstant: 150),

            back.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            back.leadingAnchor.constraint(equalTo: picker.trailingAnchor, constant: 12),
            forward.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            forward.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 8),
            reload.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            reload.leadingAnchor.constraint(equalTo: forward.trailingAnchor, constant: 8),
            zoomIn.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            zoomIn.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            zoomOut.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            zoomOut.trailingAnchor.constraint(equalTo: zoomIn.leadingAnchor, constant: -8),

            defineSel.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 6),
            defineSel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            defineEl.centerYAnchor.constraint(equalTo: defineSel.centerYAnchor),
            defineEl.leadingAnchor.constraint(equalTo: defineSel.trailingAnchor, constant: 8),
            showFolder.centerYAnchor.constraint(equalTo: defineSel.centerYAnchor),
            showFolder.leadingAnchor.constraint(equalTo: defineEl.trailingAnchor, constant: 8),
            copyAll.centerYAnchor.constraint(equalTo: defineSel.centerYAnchor),
            copyAll.leadingAnchor.constraint(equalTo: showFolder.trailingAnchor, constant: 8),
            copyAll.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -10),

            webView.topAnchor.constraint(equalTo: defineSel.bottomAnchor, constant: 8),
            webView.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])

        view = v
        let savedZoom = UserDefaults.standard.double(forKey: Self.zoomKey)
        if savedZoom > 0 { webView.pageZoom = max(0.5, min(2.0, savedZoom)) }
        webView.load(URLRequest(url: currentChat.home))
    }

    @objc private func showFolderClicked() {
        guard let url = requestFileURL?() else {
            onStatus?("Open a file first, then its folder can be shown")
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        onStatus?("\(url.lastPathComponent) is selected in Finder, drag it into the chat")
    }

    /// Past this, pasting into a chat page is what freezes it.
    private static let pasteWarnBytes = 2 * 1_048_576

    @objc private func copyWholeFileClicked() {
        guard let text = requestWholeFile?(), !text.isEmpty else {
            onStatus?("Open a file first, then it can be copied")
            NSSound.beep()
            return
        }
        let bytes = text.utf8.count
        let size = bytes >= 1_048_576
            ? String(format: "%.1f MB", Double(bytes) / 1_048_576)
            : "\(bytes / 1024) KB"

        // A chat page is a web page: pasting millions of characters into
        // it locks it up, which is not something this app can fix from
        // the outside. So a big file offers the thing that does work,
        // handing the chat the file itself.
        if bytes > Self.pasteWarnBytes {
            let a = NSAlert()
            a.messageText = "This file is \(size)"
            a.informativeText = "Pasting that much text into a chat page usually freezes the page: the site has to lay out every character. Chats take the FILE instead, and read it properly.\n\nDrag the file into the chat box: the button opens its folder in Finder with the file already selected. You can also drag any element out of the tree, or any text you select in the source, straight into the chat."
            a.addButton(withTitle: "Show the File in Finder")
            a.addButton(withTitle: "Copy Anyway")
            a.addButton(withTitle: "Cancel")
            switch a.runModal() {
            case .alertFirstButtonReturn:
                showFolderClicked()
                return
            case .alertThirdButtonReturn:
                return
            default:
                break                      // copy anyway, they were warned
            }
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.setString(text, forType: .string) else {
            onStatus?("The file is too large for the clipboard, use 📁 Folder and drag the file in instead")
            NSSound.beep()
            return
        }
        onStatus?("The whole file is copied (\(size)), click the chat box and press ⌘V")
    }

    /// Switches the pane to `chat` from outside (the Settings window).
    func showChat(_ chat: Chat) {
        currentChat = chat
        picker?.selectItem(at: chat.rawValue)
        webView?.load(URLRequest(url: chat.home))
    }

    @objc private func chatChanged(_ sender: NSPopUpButton) {
        guard let chat = Chat(rawValue: sender.indexOfSelectedItem) else { return }
        currentChat = chat
        webView.load(URLRequest(url: chat.home))
    }

    // Share-menu entry point: make sure `chat` is showing, then type
    // the prompt into its box. If the page (or a fresh navigation)
    // is still loading, the prompt parks in pendingPrompt and fires
    // from didFinish, chat SPAs render their input box late, hence
    // the extra delay.
    func openAndInsert(chat: Chat, prompt: String) {
        if currentChat != chat || view.superview == nil {
            currentChat = chat
            picker.selectItem(at: chat.rawValue)
            pendingPrompt = prompt
            webView.load(URLRequest(url: chat.home))
            return
        }
        if webView.isLoading {
            pendingPrompt = prompt
        } else {
            insertPrompt(prompt)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let prompt = pendingPrompt else { return }
        pendingPrompt = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.insertPrompt(prompt)
        }
    }

    @objc private func reloadClicked() { webView.reload() }
    @objc private func backClicked()    { webView.goBack() }
    @objc private func forwardClicked() { webView.goForward() }

    // Page zoom, persisted so his preferred reading size sticks.
    private static let zoomKey = "xml-macker.learnZoom"
    private func applyZoom(_ z: Double) {
        let clamped = max(0.5, min(2.0, z))
        webView.pageZoom = clamped
        UserDefaults.standard.set(clamped, forKey: Self.zoomKey)
    }
    @objc private func zoomInClicked()  { applyZoom(Double(webView.pageZoom) + 0.1) }
    @objc private func zoomOutClicked() { applyZoom(Double(webView.pageZoom) - 0.1) }

    @objc private func defineSelectionClicked() {
        guard let prompt = requestSelectionPrompt?() else { return }
        insertPrompt(prompt)
    }

    @objc private func defineElementClicked() {
        guard let prompt = requestElementPrompt?() else { return }
        insertPrompt(prompt)
    }

    // Type `prompt` into the chat's input box WITHOUT sending. The
    // text also always lands on the clipboard as the fallback.
    func insertPrompt(_ prompt: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)

        guard let payload = try? String(data: JSONEncoder().encode([prompt]), encoding: .utf8) else {
            onStatus?("Copied, click the chat box and press ⌘V")
            return
        }
        // Textareas in React apps need the native value setter +
        // an input event or the page ignores the change; ProseMirror
        // contenteditables take execCommand insertText at the caret.
        let js = """
        (function(arr){
          var t = arr[0];
          var el = document.querySelector('#prompt-textarea')
                || document.querySelector('div[contenteditable="true"]')
                || document.querySelector('textarea');
          if (!el) { return 'nofield'; }
          el.focus();
          if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') {
            var proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype
                                                  : window.HTMLInputElement.prototype;
            var setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
            setter.call(el, (el.value ? el.value + '\\n\\n' : '') + t);
            el.dispatchEvent(new Event('input', { bubbles: true }));
          } else {
            document.execCommand('insertText', false, t);
          }
          return 'ok';
        })(\(payload))
        """
        let chatName = currentChat.title
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            if (result as? String) == "ok" {
                self?.onStatus?("Typed into \(chatName), add your question, then press Return")
            } else {
                self?.onStatus?("Couldn't find \(chatName)'s chat box, click it and press ⌘V (text is copied)")
            }
        }
    }

    // Theme hook, the web page has its own colors; just the header.
    func rebuildColors() {
        titleLabel.textColor = XMColor.text3
    }
}
