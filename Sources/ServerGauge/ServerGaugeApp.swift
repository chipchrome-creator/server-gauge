// ============================================================
//  Server Gauge — menu bar app showing which project dev servers
//  are running (project folder · port · memory) with a stop
//  button per server. RAM Gauge's shape, aimed at localhost.
//
//  `ServerGauge --scan` prints the scan as text and exits —
//  used for headless testing.
// ============================================================

import SwiftUI
import AppKit
import Combine
import ServiceManagement

@main
struct ServerGaugeApp: App {
    // The status item is managed directly in AppKit: SwiftUI's MenuBarExtra
    // renders its label once and never refreshes it (verified — the panel
    // updated while the icon stayed frozen), so the bell/checkmark badges
    // could never appear. NSStatusItem redraws whenever we tell it to.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        if CommandLine.arguments.contains("--scan") {
            for s in scanServers() {
                let ports = s.ports.map { ":\($0)" }.joined(separator: " ")
                print("\(s.project) | \(s.command) | \(ports) | \(Int(s.rssMB)) MB | \(s.cwd)")
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--login-status") {
            print("login item: \(SMAppService.mainApp.status == .enabled ? "enabled" : "not enabled")")
            exit(0)
        }
        // First launch: register as a login item so the gauge survives
        // reboots out of the box. The footer toggle controls it after that.
        let d = UserDefaults.standard
        if !d.bool(forKey: "loginItemConfigured") {
            d.set(true, forKey: "loginItemConfigured")
            try? SMAppService.mainApp.register()
        }
    }

    var body: some Scene {
        Settings { EmptyView() } // no windows — the status item is the app
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = ServerModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var subs = Set<AnyCancellable>()
    private var pulseTimer: Timer?
    private var pulseOn = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        ClaudeAlerts.shared.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ServerListView(model: model))

        // objectWillChange fires before the mutation lands, so hop to the
        // next runloop turn to draw the post-change state.
        for change in [model.objectWillChange.eraseToAnyPublisher(),
                       ClaudeAlerts.shared.objectWillChange.eraseToAnyPublisher()] {
            change
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in DispatchQueue.main.async { self?.renderStatusItem() } }
                .store(in: &subs)
        }
        renderStatusItem()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /** Starts/stops the attention pulse (input alerts only) and redraws. */
    private func renderStatusItem() {
        if ClaudeAlerts.shared.inputCount > 0 {
            if pulseTimer == nil {
                pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.pulseOn.toggle()
                    self.drawStatusImage()
                }
            }
        } else {
            pulseTimer?.invalidate()
            pulseTimer = nil
            pulseOn = true
        }
        drawStatusImage()
    }

    /** Redraws the menu bar icon: server rack + running count, then an
     *  orange pulsing bell (+count) while Claude sessions wait on input, or
     *  a green checkmark for unseen "done"s. With no alerts it's a plain
     *  template image so macOS tints it with the menu bar; with alerts it's
     *  drawn in explicit colors matched to the menu bar's appearance. */
    private func drawStatusImage() {
        enum Piece {
            case icon(NSImage, alpha: CGFloat)
            case text(String, NSColor)
        }
        let alerts = ClaudeAlerts.shared
        let colored = alerts.inputCount > 0 || alerts.doneCount > 0
        let isDark = statusItem.button?.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // Template images only use alpha, so black works for both paths.
        let mono: NSColor = colored ? (isDark ? .white : .black) : .black

        var pieces: [Piece] = []
        if let rack = symbol("server.rack", size: 13) {
            pieces.append(.icon(colored ? tinted(rack, mono) : rack, alpha: 1))
        }
        if !model.servers.isEmpty { pieces.append(.text("\(model.servers.count)", mono)) }
        if alerts.inputCount > 0 {
            let alpha: CGFloat = pulseOn ? 1 : 0.35
            if let bell = symbol("bell.badge.fill", size: 12) {
                pieces.append(.icon(tinted(bell, .systemOrange), alpha: alpha))
            }
            if alerts.inputCount > 1 { pieces.append(.text("\(alerts.inputCount)", .systemOrange)) }
        } else if alerts.doneCount > 0 {
            if let check = symbol("checkmark.circle.fill", size: 12) {
                pieces.append(.icon(tinted(check, .systemGreen), alpha: 1))
            }
        }

        func attrs(_ color: NSColor) -> [NSAttributedString.Key: Any] {
            [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: color]
        }
        let height: CGFloat = 18
        let spacing: CGFloat = 3
        var width: CGFloat = -spacing
        for p in pieces {
            switch p {
            case let .icon(i, _): width += i.size.width + spacing
            case let .text(s, c): width += (s as NSString).size(withAttributes: attrs(c)).width + spacing
            }
        }

        let image = NSImage(size: NSSize(width: max(width, 1), height: height))
        image.lockFocus()
        var x: CGFloat = 0
        for p in pieces {
            switch p {
            case let .icon(i, alpha):
                i.draw(
                    in: NSRect(x: x, y: (height - i.size.height) / 2, width: i.size.width, height: i.size.height),
                    from: .zero, operation: .sourceOver, fraction: alpha
                )
                x += i.size.width + spacing
            case let .text(s, c):
                let sz = (s as NSString).size(withAttributes: attrs(c))
                (s as NSString).draw(at: NSPoint(x: x, y: (height - sz.height) / 2), withAttributes: attrs(c))
                x += sz.width + spacing
            }
        }
        image.unlockFocus()
        image.isTemplate = !colored
        statusItem.button?.image = image
    }

    private func symbol(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
    }

    private func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let img = NSImage(size: image.size)
        img.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        img.unlockFocus()
        return img
    }
}

/** Shared scan state — one background timer feeds both the badge and the
 *  open panel. */
final class ServerModel: ObservableObject {
    @Published var servers: [ServerInfo] = []
    @Published var lastScan: Date? = nil
    private var scanning = false
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = scanServers()
            DispatchQueue.main.async {
                self?.servers = found
                self?.lastScan = Date()
                self?.scanning = false
            }
        }
    }

    func stop(_ s: ServerInfo) {
        if killpg(s.pgid, SIGTERM) != 0 { kill(s.id, SIGTERM) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refresh() }
    }
}

struct ServerListView: View {
    @ObservedObject var model: ServerModel
    @ObservedObject var alerts = ClaudeAlerts.shared
    @State private var startAtLogin = SMAppService.mainApp.status == .enabled

    private var servers: [ServerInfo] { model.servers }
    private var lastScan: Date? { model.lastScan }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Dev Servers").font(.headline)
                Spacer()
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh now")
            }

            if servers.isEmpty {
                Text(lastScan == nil ? "Scanning…" : "No project servers are listening.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }

            ForEach(servers) { s in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(s.project).fontWeight(.semibold)
                            ForEach(s.ports, id: \.self) { port in
                                Button {
                                    NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!)
                                } label: {
                                    Text(":\(port)")
                                        .font(.system(.caption, design: .monospaced))
                                        .underline()
                                        .foregroundStyle(.teal)
                                }
                                .buttonStyle(.plain)
                                .help("Open http://localhost:\(port)")
                            }
                        }
                        Text("\(s.command) · \(fmtMB(s.rssMB)) · pid \(s.id)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(s.cwd)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help(s.fullCommand)
                    Spacer(minLength: 4)
                    Button {
                        stop(s)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .imageScale(.large)
                    }
                    .buttonStyle(.plain)
                    .help("Stop \(s.project) (SIGTERM)")
                }
                .padding(.vertical, 2)
            }

            if !alerts.pending.isEmpty {
                Divider()
                Text("Claude Code").font(.headline)
                ForEach(alerts.pending) { e in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: e.kind == .input ? "bell.badge.fill" : "checkmark.circle.fill")
                            .foregroundStyle(e.kind == .input ? Color.orange : Color.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.kind == .input ? "\(e.project) needs your input" : "\(e.project) is done")
                                .fontWeight(.semibold)
                            if !e.message.isEmpty {
                                Text(e.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Text(e.date, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 4)
                        Button {
                            alerts.dismiss(e)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .imageScale(.large)
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                    }
                    .padding(.vertical, 2)
                }
            }

            Divider()
            HStack {
                Toggle("Start at login", isOn: $startAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .onChange(of: startAtLogin) { on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                    }
                Spacer()
                if let t = lastScan {
                    Text("Updated \(t.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button("Quit") { NSApp.terminate(nil) }
                    .font(.caption)
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { model.refresh() }
        // "Done" items have been seen once the panel closes — clear them so
        // the checkmark badge doesn't linger.
        .onDisappear { alerts.clearDone() }
    }

    private func fmtMB(_ mb: Double) -> String {
        mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : "\(Int(mb)) MB"
    }

    private func refresh() { model.refresh() }

    private func stop(_ s: ServerInfo) { model.stop(s) }
}
