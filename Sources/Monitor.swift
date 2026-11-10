import AppKit
import CryptoKit
import ServiceManagement
import SwiftUI
import WebKit

@MainActor
final class Monitor: NSObject, NSApplicationDelegate, NSPopoverDelegate, ObservableObject, WKUIDelegate,
    WKNavigationDelegate
{
    @Published private(set) var usage: Usage?
    @Published private(set) var history: UsageHistory?
    @Published private(set) var tokenMonDays: [String: Double] = [:]

    var recordedDays: [String: Double] {
        // Both apps sample the same cumulative pool, so overlapping days cannot be added.
        (history?.days ?? [:]).merging(tokenMonDays, uniquingKeysWith: max)
    }

    private func importTokenMonHistory() {
        struct Import: Decodable { let dayTotals: [String: Double] }
        let url = URL.applicationSupportDirectory
            .appending(path: "TokenMon/activity_grokbot_daily_usage.dat")
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: "tokenMonDays")
        let savedDays = saved.flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
        let source = try? JSONDecoder().decode(Import.self, from: Data(contentsOf: url))
        tokenMonDays = savedDays.merging(source?.dayTotals ?? [:], uniquingKeysWith: max)
        if tokenMonDays != savedDays, let data = try? JSONEncoder().encode(tokenMonDays) {
            defaults.set(data, forKey: "tokenMonDays")
        }
    }
    @Published private(set) var prepaidBalance: Decimal?
    @Published private var billing: GrokBilling?
    @Published private var productHistory: ProductHistory?
    @Published private(set) var creditsSignedIn = false
    @Published private(set) var checkingCredits = false
    @Published private(set) var error: String?
    @Published private(set) var needsSignIn = false
    @Published private(set) var refreshing = false
    @Published private(set) var weekly = UserDefaults.standard.bool(forKey: "weekly")

    private let client = UsageClient()
    private let store = WKWebsiteDataStore.default()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let overviewPopover = NSPopover()
    private var outsideClickMonitor: Any?
    private var signInWindow: NSWindow?
    private var signingIntoGrok = false
    private var loginPopups: [NSWindow] = []
    private var polling: Task<Void, Never>?

    var calendar: Calendar { .autoupdatingCurrent }

    var todayUsed: Double? {
        guard let usage, calendar.isDateInToday(usage.sampledAt), usage.included else { return nil }
        return recordedDays[UsageHistory.dayKey(usage.sampledAt, calendar: calendar)]
    }

    var todayBudget: (share: Double, left: Double)? {
        guard let usage, usage.included, let window = usage.window(calendar: calendar),
              calendar.isDateInToday(usage.sampledAt), usage.reset.map({ $0 > Date() }) == true else { return nil }
        let elapsed = calendar.dateComponents([.day], from: window.firstDay, to: calendar.startOfDay(for: usage.sampledAt)).day ?? 0
        let share = 100 / Double(window.count)
        let available = min(100, share * Double(max(1, elapsed + 1)))
        return (share, available - usage.used)
    }

    var weeklySlices: [ProductSlice] {
        guard let usage else { return [] }
        return ProductSlice.split(matchingProductWindow ? billing?.products ?? [:] : [:], total: usage.used)
    }

    func dailySlices(day: String, total: Double) -> [ProductSlice] {
        ProductSlice.split(matchingProductWindow ? productHistory?.days[day] ?? [:] : [:], total: total)
    }

    private var matchingProductWindow: Bool {
        guard let reset = billing?.currentPeriod?.reset, let cursorReset = usage?.reset else { return false }
        return reset > Date() && abs(reset.timeIntervalSince(cursorReset)) < 60
    }

    var meterValue: Double? {
        guard let usage, usage.included, usage.reset.map({ $0 > Date() }) ?? true else { return nil }
        if weekly { return usage.used }
        guard let todayUsed, let todayBudget else { return nil }
        let budgetAtStart = todayBudget.left + todayUsed
        return budgetAtStart > 0 ? min(100, todayUsed / budgetAtStart * 100) : 100
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        importTokenMonHistory()
        overviewPopover.behavior = .transient
        overviewPopover.delegate = self
        let hosting = NSHostingController(rootView: Overview(monitor: self).frame(width: 355))
        hosting.sizingOptions = [.preferredContentSize]
        overviewPopover.contentViewController = hosting

        statusItem.button?.target = self
        statusItem.button?.action = #selector(clicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        renderMeter()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            weekly.toggle()
            UserDefaults.standard.set(weekly, forKey: "weekly")
            renderMeter()
        } else if overviewPopover.isShown {
            overviewPopover.performClose(nil)
        } else {
            showOverview()
            Task { await refresh() }
        }
    }

    private func showOverview() {
        guard let button = statusItem.button else { return }
        importTokenMonHistory()
        overviewPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            self?.closePopoverIfClickedOutside(event)
        }
    }

    private func stopOutsideClickMonitor() {
        outsideClickMonitor.map { NSEvent.removeMonitor($0) }
        outsideClickMonitor = nil
    }

    private func closePopoverIfClickedOutside(_ event: NSEvent) {
        guard overviewPopover.isShown else { return }
        if let popoverWindow = overviewPopover.contentViewController?.view.window, event.window === popoverWindow {
            return
        }
        if let button = statusItem.button, let buttonWindow = button.window, event.window === buttonWindow,
           button.bounds.contains(button.convert(event.locationInWindow, from: nil)) {
            return
        }
        overviewPopover.performClose(nil)
    }

    func popoverDidShow(_ notification: Notification) {
        startOutsideClickMonitor()
    }

    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitor()
    }

    private func renderMeter() {
        let mode = weekly ? "Week" : "Day"
        let value = meterValue
        let displayValue = weekly ? value : todayUsed
        let label = "\(mode) \(displayValue.map { percent($0, digits: 0) } ?? "–")"
        let day = UsageHistory.dayKey(Date(), calendar: calendar)
        let slices = weekly ? weeklySlices : dailySlices(day: day, total: todayUsed ?? 0)
        let segmented = slices.contains { $0.id != .other }
        let foreground = segmented ? NSColor.labelColor : NSColor.black
        let trackWidth: CGFloat = segmented ? 50 : 35
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
        let text = NSAttributedString(string: label, attributes: attributes)
        let size = text.size()
        let image = NSImage(size: NSSize(width: ceil(size.width) + 6 + trackWidth, height: 18), flipped: false) { rect in
            text.draw(at: NSPoint(x: 0, y: (rect.height - size.height) / 2))
            let track = NSRect(x: ceil(size.width) + 6, y: 6, width: trackWidth, height: 6)
            let outline = NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3)
            foreground.withAlphaComponent(0.24).setFill()
            outline.fill()
            if let value, value > 0 {
                outline.addClip()
                let fillWidth = track.width * value / 100
                if segmented {
                    var x = track.minX
                    for slice in slices {
                        let width = fillWidth * slice.fraction
                        slice.id.tint.setFill()
                        NSBezierPath(rect: NSRect(x: x, y: track.minY, width: width, height: track.height)).fill()
                        x += width
                    }
                } else {
                    foreground.setFill()
                    NSBezierPath(rect: NSRect(x: track.minX, y: track.minY, width: fillWidth, height: track.height)).fill()
                }
            }
            return true
        }
        image.isTemplate = !segmented
        image.accessibilityDescription = "Grokus \(label)"
        statusItem.button?.image = image
        let budget = weekly ? nil : value.map { "\(percent($0, digits: 0)) of today's budget used" }
        statusItem.button?.toolTip = ["Grokus", label, budget, "Right-click to switch Day / Week"]
            .compactMap { $0 }.joined(separator: " · ")
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        Task { await refreshCredits() }
        defer {
            refreshing = false
            renderMeter()
        }

        let cookies = await store.httpCookieStore.allCookies()
        guard let session = cookies.filter({
            $0.name == "WorkosCursorSessionToken" && ($0.domain == "cursor.com" || $0.domain == ".cursor.com")
                && ($0.expiresDate.map { $0 > Date() } ?? true)
        }).max(by: { ($0.expiresDate ?? .distantFuture) < ($1.expiresDate ?? .distantFuture) }) else {
            usage = nil
            error = UsageError.signedOut.localizedDescription
            needsSignIn = true
            return
        }

        let fingerprint = SHA256.hash(data: Data(session.value.utf8)).description
        let cookie = "\(session.name)=\(session.value)"
        let stored = history ?? UserDefaults.standard.data(forKey: "history").flatMap {
            try? JSONDecoder().decode(UsageHistory.self, from: $0)
        }
        if stored?.session != fingerprint {
            usage = nil
        }

        do {
            let fresh = try await client.fetch(cookie: cookie)
            var updated = stored.flatMap { $0.session == fingerprint ? $0 : nil } ?? UsageHistory(session: fingerprint)
            updated.record(fresh, calendar: calendar)
            history = updated
            usage = fresh
            error = nil
            needsSignIn = false
            if let encoded = try? JSONEncoder().encode(updated) {
                UserDefaults.standard.set(encoded, forKey: "history")
            }
            renderMeter()
        } catch {
            self.error = error.localizedDescription
            if case UsageError.signedOut = error { needsSignIn = true }
        }
    }

    private func refreshCredits() async {
        guard !checkingCredits else { return }
        checkingCredits = true
        defer {
            checkingCredits = false
            renderMeter()
        }
        let cookies = await store.httpCookieStore.allCookies().filter {
            ($0.domain == ".grok.com" || $0.domain == "grok.com")
                && ["sso", "sso-rw"].contains($0.name)
                && ($0.expiresDate.map { $0 > Date() } ?? true)
        }
        creditsSignedIn = !cookies.isEmpty
        guard creditsSignedIn else {
            prepaidBalance = nil
            billing = nil
            productHistory = nil
            return
        }
        let cookie = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        guard let fresh = try? await GrokBilling.fetch(cookie: cookie) else { return }
        prepaidBalance = fresh.prepaidBalance?.dollars
        billing = fresh
        guard let reset = fresh.currentPeriod?.reset, let products = fresh.productUsage, !products.isEmpty else { return }
        let identity = cookies.first(where: { $0.name == "sso" })?.value ?? cookie
        let session = SHA256.hash(data: Data(identity.utf8)).description
        let defaults = UserDefaults.standard
        let saved = productHistory ?? defaults.data(forKey: "productHistory").flatMap {
            try? JSONDecoder().decode(ProductHistory.self, from: $0)
        }
        let now = Date()
        let today = UsageHistory.dayKey(now, calendar: calendar)
        let previous = saved.flatMap { $0.session == session ? $0 : nil }
        var next = previous.flatMap { $0.reset == reset ? $0 : nil }
            ?? ProductHistory(
                session: session, reset: reset, last: fresh.products,
                days: previous?.days.filter { $0.key < today } ?? [:]
            )
        next.record(fresh.products, day: today)
        if let cutoff = calendar.date(byAdding: .day, value: -40, to: now) {
            let first = UsageHistory.dayKey(cutoff, calendar: calendar)
            next.days = next.days.filter { $0.key >= first }
        }
        productHistory = next
        if let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: "productHistory")
        }
    }

    func signIn(toGrok: Bool = false) {
        overviewPopover.performClose(nil)
        if let signInWindow, signInWindow.isVisible {
            signInWindow.makeKeyAndOrderFront(nil)
            return
        }

        signingIntoGrok = toGrok
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        let container = NSView()
        let done = NSButton(title: toGrok ? "Refresh Credits and Return" : "Check Sign-In",
                            target: self, action: #selector(checkSignIn))
        let stack = NSStackView(views: [web, done])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            web.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        let window = browserWindow(title: toGrok ? "Sign in to Grok" : "Sign in to Cursor", view: container)
        signInWindow = window
        web.load(URLRequest(url: toGrok ? GrokBilling.dashboard : UsageClient.dashboard))
    }

    @objc private func checkSignIn() {
        Task {
            if signingIntoGrok {
                await refreshCredits()
                guard creditsSignedIn else { return }
            } else {
                await refresh()
                guard error == nil else { return }
            }
            signInWindow?.close()
            for popup in loginPopups { popup.close() }
            loginPopups.removeAll()
            showOverview()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A valid Grok session may already be present when the billing page opens.
        // Keep it visible so the user can inspect billing or finish signing in.
        guard !signingIntoGrok, signInWindow?.isVisible == true, webView.url?.host == "cursor.com",
              webView.url?.path.hasPrefix("/dashboard") == true else { return }
        checkSignIn()
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.uiDelegate = self
        popup.navigationDelegate = self
        loginPopups.removeAll { !$0.isVisible }
        loginPopups.append(browserWindow(title: "Cursor Sign-In", view: popup))
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        loginPopups.first { $0.contentView === webView }?.close()
        loginPopups.removeAll { !$0.isVisible }
    }

    private func browserWindow(title: String, view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 850, height: 640),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

@main
struct Grokus {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--register-login-item" {
            let service = SMAppService.mainApp
            do {
                if service.status != .enabled && service.status != .requiresApproval { try service.register() }
                guard service.status == .enabled else {
                    fputs("Enable Grokus in System Settings → Login Items.\n", stderr)
                    exit(1)
                }
                print("Grokus is registered as a login item.")
            } catch {
                fputs("Could not register Grokus: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        let app = NSApplication.shared
        let monitor = Monitor()
        app.delegate = monitor
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(monitor) { app.run() }
    }
}
