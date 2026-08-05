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
import ServiceManagement

@main
struct ServerGaugeApp: App {
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

    @StateObject private var model = ServerModel()

    var body: some Scene {
        MenuBarExtra {
            ServerListView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/** Icon + live count of running project servers. The scan runs on the
 *  model's own timer, so the badge stays fresh with the popover closed. */
struct MenuBarLabel: View {
    @ObservedObject var model: ServerModel
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "server.rack")
            if !model.servers.isEmpty {
                Text("\(model.servers.count)")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
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
    }

    private func fmtMB(_ mb: Double) -> String {
        mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : "\(Int(mb)) MB"
    }

    private func refresh() { model.refresh() }

    private func stop(_ s: ServerInfo) { model.stop(s) }
}
