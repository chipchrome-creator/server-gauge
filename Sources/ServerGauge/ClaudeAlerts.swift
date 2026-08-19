// ============================================================
//  ClaudeAlerts — surfaces Claude Code activity as macOS
//  notifications and menu-bar state. Stop/Notification/
//  UserPromptSubmit hooks in ~/.claude/settings.json drop JSON
//  event files into ~/.claude/servergauge-events/; this watches
//  the folder, posts "done" / "needs your input" notifications
//  tagged with the project, and keeps a pending list the menu
//  bar badge and panel section render. An "ack" event (the user
//  answered that session) clears its pending entry.
// ============================================================

import AppKit
import Foundation
import UserNotifications

struct ClaudeEvent: Identifiable, Equatable {
    enum Kind { case input, done }
    let id = UUID()
    let kind: Kind
    let cwd: String
    let session: String
    let project: String
    let message: String
    let date: Date

    /** Pending items are one-per-session so a second session in the same
     *  project can't clear or mask the first one's alert. Old events
     *  without a session id fall back to the directory. */
    var key: String { session.isEmpty ? cwd : session }
}

final class ClaudeAlerts: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = ClaudeAlerts()
    /** One entry per session working directory — the latest event wins. */
    @Published var pending: [ClaudeEvent] = [] {
        didSet { writeStateFile() }
    }
    var inputCount: Int { pending.filter { $0.kind == .input }.count }
    var doneCount: Int { pending.filter { $0.kind == .done }.count }

    private let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/servergauge-events")
    private var source: DispatchSourceFileSystemObject?
    private var pruneTimer: Timer?

    func start() {
        // UNUserNotificationCenter traps when the process isn't a real .app
        // bundle (the bare .build binary used by --scan), so bail there.
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Watch first, then clear the backlog: the reverse order can lose an
        // event that lands between the drain and the watcher install.
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.drain(notify: true) }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src

        // Events queued while the gauge wasn't running are stale — clear
        // them silently rather than replaying a burst of old banners.
        drain(notify: false)

        // Reconciliation: vnode notifications can coalesce or drop, so
        // re-scan periodically (and prune expired "done" items).
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.drain(notify: true)
            self?.prune()
        }
    }

    /** Consume every completed event file in the folder, oldest write
     *  first so causally ordered events (input → ack) apply in order.
     *  Hooks write to a .tmp name and mv to .json, so a .json file is
     *  always whole; .tmp files still being written are left alone. */
    private func drain(notify: Bool) {
        let fm = FileManager.default
        let dirURL = URL(fileURLWithPath: dir)
        guard let urls = try? fm.contentsOfDirectory(
            at: dirURL, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        func mtime(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        for url in urls.filter({ $0.pathExtension == "json" }).sorted(by: { mtime($0) < mtime($1) }) {
            defer { try? fm.removeItem(at: url) }
            guard notify,
                  let data = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            handle(
                event: obj["event"] as? String ?? "",
                cwd: obj["cwd"] as? String ?? "",
                session: obj["session"] as? String ?? "",
                message: obj["message"] as? String ?? ""
            )
        }
    }

    private func handle(event: String, cwd: String, session: String, message: String) {
        let project = cwd.isEmpty ? "Claude Code" : projectName(from: cwd)
        let key = session.isEmpty ? cwd : session
        // Latest event per session replaces whatever came before it — a
        // stop supersedes its input request, an ack (user answered) clears.
        pending.removeAll { $0.key == key }
        switch event {
        case "input":
            pending.append(ClaudeEvent(
                kind: .input, cwd: cwd, session: session, project: project, message: message, date: Date()
            ))
            post(title: "\(project) — Claude needs your input",
                 body: message.isEmpty ? "A session is waiting on you." : message)
        case "stop":
            pending.append(ClaudeEvent(
                kind: .done, cwd: cwd, session: session, project: project, message: message, date: Date()
            ))
            post(title: "\(project) — Claude is done",
                 body: "The session finished and is ready for you.")
        default:
            break // "ack" — the removal above is the whole job
        }
        prune()
    }

    func dismiss(_ e: ClaudeEvent) { pending.removeAll { $0.id == e.id } }

    /** "Done" items are informational — once the panel has been seen,
     *  they've served their purpose. */
    func clearDone() {
        if doneCount > 0 { pending.removeAll { $0.kind == .done } }
    }

    /** Unseen "done" badges shouldn't linger forever. */
    private func prune() {
        let cutoff = Date().addingTimeInterval(-1800)
        if pending.contains(where: { $0.kind == .done && $0.date < cutoff }) {
            pending.removeAll { $0.kind == .done && $0.date < cutoff }
        }
    }

    /** Mirror of `pending` for headless debugging — lets a shell confirm
     *  what state the running app actually holds. */
    private func writeStateFile() {
        let items = pending.map {
            ["kind": $0.kind == .input ? "input" : "done", "project": $0.project, "cwd": $0.cwd, "session": $0.session]
        }
        if let data = try? JSONSerialization.data(withJSONObject: ["pending": items]) {
            try? data.write(to: URL(fileURLWithPath: (NSHomeDirectory() as NSString)
                .appendingPathComponent(".claude/servergauge-state.json")))
        }
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    /** Menu-bar apps count as "running", which normally suppresses banners —
     *  present them anyway. */
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
