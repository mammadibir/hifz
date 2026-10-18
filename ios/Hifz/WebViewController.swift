import SafariServices
import UIKit
import WebKit

/// The whole app is the hifz website shown full screen, so every update to the site
/// reaches the app at once. The native side adds what the site cannot do on iPhone (see BridgeScript).
final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    /// The copy on Yandex Cloud opens in Russia without VPN; the one on GitHub is the fallback if it does not answer.
    static let homes = [URL(string: "https://hifz-mammadibir.website.yandexcloud.net/")!,
                        URL(string: "https://mammadibir.github.io/hifz/")!]
    static let home = homes[0]
    static let appHosts: Set<String> = ["hifz-mammadibir.website.yandexcloud.net", "mammadibir.github.io"]

    private var webView: WKWebView!
    private let speech = SpeechBridge()
    private let feedback = Feedback()
    private var themeObservation: NSKeyValueObservation?
    private var statusStyle: UIStatusBarStyle = .default
    private let offlineView = UIView()
    private var triedCache = false
    private var homeIndex = 0
    private var triedOtherHome = false
    private var loadedOnce = false
    private var debugScriptRan = false

    override var preferredStatusBarStyle: UIStatusBarStyle { statusStyle }

    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version).\(build)"
    }

    /// For screenshots in the build pipeline a different start address can be passed as a launch argument.
    static var overrideURL: URL? {
        if let s = UserDefaults.standard.string(forKey: "hifzStartURL"), let url = URL(string: s) { return url }
        return nil
    }

    private var startURL: URL { Self.overrideURL ?? Self.homes[homeIndex] }

    static func isAppPage(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "hifz-mammadibir.website.yandexcloud.net" { return true }
        return host == "mammadibir.github.io" && (url.path == "/hifz" || url.path.hasPrefix("/hifz/"))
    }

    // MARK: - View

    override func loadView() {
        let background = UIColor(named: "LaunchBg") ?? .systemBackground

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.applicationNameForUserAgent = "HifzApp/\(Self.appVersion)"
        let content = WKUserContentController()
        let script = BridgeScript.source.replacingOccurrences(of: "__APP_VERSION__", with: Self.appVersion)
        content.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.add(WeakMessageHandler(self), name: "hifz")
        config.userContentController = content

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = false
        web.allowsLinkPreview = false
        web.isOpaque = false
        web.backgroundColor = background
        web.scrollView.backgroundColor = background
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false
        if #available(iOS 16.4, *) { web.isInspectable = true }
        webView = web
        speech.webView = web

        let root = UIView()
        root.backgroundColor = background
        web.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            web.topAnchor.constraint(equalTo: root.topAnchor),
            web.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        buildOfflineView(in: root, background: background)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        themeObservation = webView.observe(\.themeColor, options: [.initial, .new]) { [weak self] web, _ in
            DispatchQueue.main.async { self?.applyTheme(web.themeColor) }
        }
        load()
    }

    private func load(cacheOnly: Bool = false) {
        var request = URLRequest(url: startURL)
        if cacheOnly { request.cachePolicy = .returnCacheDataDontLoad }
        webView.load(request)
    }

    /// The status bar takes the page's theme colour (light, dark or one of the app themes).
    private func applyTheme(_ color: UIColor?) {
        let bg = color ?? UIColor(named: "LaunchBg") ?? .systemBackground
        view.backgroundColor = bg
        webView.underPageBackgroundColor = bg
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard bg.resolvedColor(with: traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        statusStyle = luminance < 0.5 ? .lightContent : .darkContent
        setNeedsStatusBarAppearanceUpdate()
    }

    private func buildOfflineView(in root: UIView, background: UIColor) {
        offlineView.backgroundColor = background
        offlineView.isHidden = true
        offlineView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(offlineView)

        let title = UILabel()
        title.text = "Нет подключения к интернету"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = .label
        title.textAlignment = .center
        title.numberOfLines = 0

        let note = UILabel()
        note.text = "Приложению нужен интернет, чтобы открыться. Проверьте связь и попробуйте ещё раз."
        note.font = .preferredFont(forTextStyle: .subheadline)
        note.textColor = .secondaryLabel
        note.textAlignment = .center
        note.numberOfLines = 0

        var button = UIButton.Configuration.filled()
        button.title = "Повторить"
        button.cornerStyle = .large
        button.baseBackgroundColor = UIColor(red: 0x2A / 255.0, green: 0x4A / 255.0, blue: 0xA2 / 255.0, alpha: 1)
        let retry = UIButton(configuration: button, primaryAction: UIAction { [weak self] _ in
            guard let self = self else { return }
            self.triedCache = false
            self.triedOtherHome = false
            self.homeIndex = 0
            self.offlineView.isHidden = true
            self.load()
        })

        let stack = UIStackView(arrangedSubviews: [title, note, retry])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        offlineView.addSubview(stack)
        NSLayoutConstraint.activate([
            offlineView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            offlineView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            offlineView.topAnchor.constraint(equalTo: root.topAnchor),
            offlineView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.centerYAnchor.constraint(equalTo: offlineView.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: offlineView.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: offlineView.trailingAnchor, constant: -32),
        ])
    }

    // MARK: - Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.cancel)
            return
        }
        if ["about", "blob", "data", "javascript"].contains(scheme) {
            decisionHandler(.allow)
            return
        }
        guard scheme == "http" || scheme == "https" else {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if let frame = navigationAction.targetFrame, !frame.isMainFrame {
            decisionHandler(.allow)   // frames inside the page, e.g. the sign-in service
            return
        }
        if Self.isAppPage(url) {
            if navigationAction.targetFrame == nil {
                decisionHandler(.cancel)
                webView.load(URLRequest(url: url))
            } else {
                decisionHandler(.allow)
            }
            return
        }
        // Other sites (tafsir on azan.ru, sources) open in a Safari window over the app
        decisionHandler(.cancel)
        openExternal(url)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if Self.isAppPage(url) { webView.load(URLRequest(url: url)) } else { openExternal(url) }
        }
        return nil
    }

    /// A copy of the site that answers with an error page (not set up yet, or removed) counts as not opening.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, !loadedOnce, !triedOtherHome, Self.overrideURL == nil,
           let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400 {
            decisionHandler(.cancel)
            triedOtherHome = true
            homeIndex = 1 - homeIndex
            DispatchQueue.main.async { [weak self] in self?.load() }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadedOnce = true
        triedCache = false
        offlineView.isHidden = true
        runDebugScriptOnce()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView.url != nil { webView.reload() } else { load() }
    }

    private func loadFailed(_ error: Error) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && e.code == 102 { return }
        if !triedOtherHome && !loadedOnce && Self.overrideURL == nil {
            // The first address did not open: try the other copy of the site
            triedOtherHome = true
            homeIndex = 1 - homeIndex
            load()
            return
        }
        if !triedCache {
            // Without internet, open the copy kept from the last visit if there is one
            triedCache = true
            load(cacheOnly: true)
            return
        }
        offlineView.isHidden = false
    }

    private func openExternal(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            UIApplication.shared.open(url)
            return
        }
        let safari = SFSafariViewController(url: url)
        safari.dismissButtonStyle = .close
        (presentedViewController ?? self).present(safari, animated: true)
    }

    private func runDebugScriptOnce() {
        guard !debugScriptRan, let js = UserDefaults.standard.string(forKey: "hifzDebugJS"), !js.isEmpty else { return }
        debugScriptRan = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - Dialogs from the page

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        (presentedViewController ?? self).present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        (presentedViewController ?? self).present(alert, animated: true)
    }

    // MARK: - Messages from the page

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              Self.appHosts.contains(message.frameInfo.securityOrigin.host.lowercased()),
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        let id = (body["id"] as? NSNumber)?.intValue ?? 0
        switch type {
        case "sr-start":
            speech.start(id: id, lang: body["lang"] as? String ?? "ar-SA", context: body["ctx"] as? [String] ?? [])
        case "sr-stop":
            speech.stop(id: id)
        case "sr-abort":
            speech.abort(id: id)
        case "haptic":
            feedback.haptic()
        case "beep":
            feedback.beep()
        case "awake":
            UIApplication.shared.isIdleTimerDisabled = (body["on"] as? Bool) ?? false
        case "open":
            if let s = body["url"] as? String, let url = URL(string: s) { openExternal(url) }
        default:
            break
        }
    }
}

/// WKUserContentController keeps its handlers strongly; this keeps the controller from never being released.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
