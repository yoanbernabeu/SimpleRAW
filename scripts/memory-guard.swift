// Runs a command and kills it, with everything it started, when one of those processes goes
// over a memory limit.
//
//     memory-guard <limit in GB> <command> [arguments…]
//
// A mistake in a Core Image graph can ask for ten gigabytes a second. The system does not
// kill such a process: it compresses, swaps, stops answering, and the watchdog reboots the
// computer. That happened three times before this guard existed, so every test and bench
// runs under it. What is watched is the physical footprint (`proc_pid_rusage`): compressed
// memory counts, which `ps` leaves out, and reading it takes microseconds.
import Darwin
import Foundation

guard CommandLine.arguments.count >= 3, let limitGB = Double(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: memory-guard <limit in GB> <command> [arguments…]\n".utf8))
    exit(64)
}
let limit = UInt64(limitGB * 1_073_741_824)

@Sendable func footprint(of pid: pid_t) -> UInt64 {
    var usage = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return status == 0 ? usage.ri_phys_footprint : 0
}

@Sendable func children(of pid: pid_t) -> [pid_t] {
    var pids = [pid_t](repeating: 0, count: 4096)
    let count = Int(proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    return count > 0 ? Array(pids.prefix(min(count, pids.count))) : []
}

@Sendable func family(of pid: pid_t) -> [pid_t] {
    [pid] + children(of: pid).flatMap(family)
}

let command = Process()
command.executableURL = URL(fileURLWithPath: "/usr/bin/env")
command.arguments = Array(CommandLine.arguments.dropFirst(2))
try command.run()
let root = command.processIdentifier

let watcher = Thread {
    while command.isRunning {
        let processes = family(of: root)
        if let culprit = processes.first(where: { footprint(of: $0) > limit }) {
            let used = Double(footprint(of: culprit)) / 1_073_741_824
            // The culprit first: every millisecond counts. Then whatever would restart it.
            kill(culprit, SIGKILL)
            processes.reversed().forEach { kill($0, SIGKILL) }
            let message = String(format: "error: memory-guard: process %d used %.1f GB, over the %.0f GB limit: killed\n", culprit, used, limitGB)
            FileHandle.standardError.write(Data(message.utf8))
            exit(137)
        }
        usleep(20_000)
    }
}
watcher.qualityOfService = .userInteractive
watcher.start()

command.waitUntilExit()
exit(command.terminationStatus)
