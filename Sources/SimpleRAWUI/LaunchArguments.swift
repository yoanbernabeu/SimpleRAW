import Foundation

/// The `-key value` pairs the app was started with.
///
/// Read from the command line itself rather than from the user defaults AppKit files them
/// into: a default can be written by any process of the user (`defaults write`), and would
/// then point every launch at a library or a file of its choosing.
/// Also: **the shipped app takes none of them**. They open a library, a file and a look of
/// another process's choosing, and drive gestures; the process that passes them already has
/// the rights of the person running it, so this is depth rather than a wall, but it is depth
/// for nothing. The line is the sandbox rather than `#if DEBUG`, because responsiveness can
/// only be judged in release (`make run`, `make bench`, `make gestures`) and those run the
/// bare executable, which is not sandboxed.
public struct LaunchArguments: Sendable {
    private let arguments: [String]

    public init(_ arguments: [String] = ProcessInfo.processInfo.arguments, isSandboxed: Bool = LaunchArguments.isSandboxed) {
        self.arguments = isSandboxed ? [] : arguments
    }

    /// Whether this process is the wrapped, sandboxed app rather than a build from the tree.
    public static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    public func value(for key: String) -> String? {
        guard let index = arguments.firstIndex(of: "-\(key)"), arguments.indices.contains(index + 1) else { return nil }
        let value = arguments[index + 1]
        return value.hasPrefix("-") ? nil : value
    }

    public func url(for key: String) -> URL? {
        value(for: key).map { URL(fileURLWithPath: $0) }
    }

    public func flag(_ key: String) -> Bool {
        ["yes", "true", "1"].contains(value(for: key)?.lowercased() ?? "")
    }
}
