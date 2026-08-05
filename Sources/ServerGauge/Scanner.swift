// ============================================================
//  Scanner — finds every process listening on a TCP port whose
//  working directory lives under the home folder (i.e. project
//  dev servers, not system daemons), and resolves the PROJECT
//  each one belongs to from that working directory.
// ============================================================

import Foundation

struct ServerInfo: Identifiable, Equatable {
    let id: Int32 // pid of the listening process
    let pgid: Int32 // process group — stop() signals the whole tree
    let command: String // short process name, e.g. "next-server (v16.2.9)"
    let ports: [Int]
    let cwd: String // absolute working directory
    let rssMB: Double // summed across the process group (workers included)
    let fullCommand: String // full argv for the tooltip

    /** Display name: the folder, walking up past generic monorepo layers
     *  ("packages", "apps", "src"…) so eddy/packages reads as "eddy". */
    var project: String {
        let generic: Set<String> = ["packages", "apps", "app", "src", "services", "server", "backend", "frontend", "web"]
        var path = cwd as NSString
        var name = path.lastPathComponent
        let home = NSHomeDirectory()
        while generic.contains(name.lowercased()), (path.deletingLastPathComponent as String).hasPrefix(home),
              (path.deletingLastPathComponent as String) != home {
            path = path.deletingLastPathComponent as NSString
            name = path.lastPathComponent
        }
        return name
    }
}

/** Activity-Monitor-style memory: phys_footprint counts private + compressed
 *  pages, so an idle dev server whose heap macOS has compressed still shows
 *  its true size (RSS would report a misleading 32 MB for a 2 GB server).
 *  Works without privileges for same-user processes. */
func footprintMB(_ pid: Int32) -> Double? {
    var usage = rusage_info_current()
    let result = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
        }
    }
    return result == 0 ? Double(usage.ri_phys_footprint) / 1_048_576 : nil
}

@discardableResult
func runTool(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    // Read BEFORE waiting so a full pipe can never deadlock the child.
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

func scanServers() -> [ServerInfo] {
    // Field output: p<pid> / c<command> / n<address> lines, grouped by process.
    let out = runTool("/usr/sbin/lsof", ["-iTCP", "-sTCP:LISTEN", "-n", "-P", "-Fpcn"])
    var pid: Int32 = 0
    var byPid: [Int32: (command: String, ports: Set<Int>)] = [:]
    for line in out.split(separator: "\n") {
        guard let tag = line.first else { continue }
        let value = String(line.dropFirst())
        switch tag {
        case "p":
            pid = Int32(value) ?? 0
        case "c":
            byPid[pid, default: ("", [])].command = value
        case "n":
            if let portStr = value.split(separator: ":").last, let port = Int(portStr) {
                byPid[pid, default: ("", [])].ports.insert(port)
            }
        default:
            break
        }
    }

    // One process-table snapshot: pid → pgid, then per-group memory as the
    // sum of each member's phys_footprint (RSS fallback), so a server row
    // reports its whole tree's true size — wrapper + workers + compressed.
    var pgidOf: [Int32: Int32] = [:]
    var memByPgid: [Int32: Double] = [:]
    for line in runTool("/bin/ps", ["-axo", "pid=,pgid=,rss="]).split(separator: "\n") {
        let cols = line.split(separator: " ", omittingEmptySubsequences: true)
        guard cols.count >= 3, let p = Int32(cols[0]), let g = Int32(cols[1]), let r = Double(cols[2]) else { continue }
        pgidOf[p] = g
        memByPgid[g, default: 0] += footprintMB(p) ?? (r / 1024)
    }

    let home = NSHomeDirectory()
    let library = home + "/Library"
    let selfPid = ProcessInfo.processInfo.processIdentifier
    var result: [ServerInfo] = []
    for (pid, info) in byPid where pid != selfPid {
        // Working directory — the "which project is this?" answer. System
        // daemons run from / or /System…; project servers run from ~/… .
        // ~/Library is excluded too (Postgres.app internals, agents) so the
        // list stays killable-dev-servers only.
        let cwdOut = runTool("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"])
        guard
            let cwdLine = cwdOut.split(separator: "\n").first(where: { $0.hasPrefix("n") }),
            case let cwd = String(cwdLine.dropFirst()),
            cwd.hasPrefix(home), cwd != home, !cwd.hasPrefix(library)
        else { continue }

        let pgid = pgidOf[pid] ?? pid
        let full = runTool("/bin/ps", ["-o", "command=", "-p", String(pid)])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        result.append(ServerInfo(
            id: pid,
            pgid: pgid,
            command: info.command,
            ports: info.ports.sorted(),
            cwd: cwd,
            rssMB: memByPgid[pgid] ?? 0,
            fullCommand: full
        ))
    }
    // One row per process TREE: a monorepo's web+api under a single
    // `npm run dev` share a pgid — show them once, ports unioned, rooted at
    // the deepest folder common to both (e.g. …/eddy, not …/eddy/packages/web).
    var byGroup: [Int32: ServerInfo] = [:]
    for s in result {
        if let existing = byGroup[s.pgid] {
            byGroup[s.pgid] = ServerInfo(
                id: existing.id,
                pgid: s.pgid,
                command: existing.command,
                ports: Array(Set(existing.ports).union(s.ports)).sorted(),
                cwd: commonPath(existing.cwd, s.cwd),
                rssMB: existing.rssMB, // group total — identical on both rows
                fullCommand: existing.fullCommand
            )
        } else {
            byGroup[s.pgid] = s
        }
    }
    return byGroup.values.sorted {
        $0.project.localizedCaseInsensitiveCompare($1.project) == .orderedAscending
    }
}

/** Deepest directory shared by two absolute paths. */
private func commonPath(_ a: String, _ b: String) -> String {
    let ca = a.split(separator: "/"), cb = b.split(separator: "/")
    var shared: [Substring] = []
    for (x, y) in zip(ca, cb) {
        if x == y { shared.append(x) } else { break }
    }
    return shared.isEmpty ? a : "/" + shared.joined(separator: "/")
}
