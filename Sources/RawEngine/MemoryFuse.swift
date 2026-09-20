import Darwin
import Foundation

/// Ends the process when it uses an absurd amount of memory.
///
/// A mistake in a Core Image graph can ask for ten gigabytes a second. macOS does not kill
/// such a process: it swaps until nothing answers, and the watchdog reboots the computer.
/// Quitting is the lesser evil: edits are saved half a second after each gesture.
public enum MemoryFuse {
    /// What the process costs the machine, compressed memory included.
    public static var footprint: UInt64 {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? usage.ri_phys_footprint : 0
    }

    /// Half of the memory of the machine: no picture needs that, and the machine survives it.
    public static var defaultLimit: UInt64 { ProcessInfo.processInfo.physicalMemory / 2 }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var isArmed = false

    /// Starts watching, for the life of the process. Calling it again changes nothing.
    public static func arm(limit: UInt64 = defaultLimit) {
        lock.lock()
        defer { lock.unlock() }
        guard !isArmed else { return }
        isArmed = true
        let watcher = Thread {
            while true {
                let used = footprint
                if used > limit {
                    let gigabytes = Double(used) / 1_073_741_824
                    FileHandle.standardError.write(Data(String(format: "MemoryFuse: %.1f GB in use, quitting before the machine stops answering\n", gigabytes).utf8))
                    abort()
                }
                usleep(10_000)
            }
        }
        watcher.qualityOfService = .userInteractive
        watcher.name = "MemoryFuse"
        watcher.start()
    }
}
