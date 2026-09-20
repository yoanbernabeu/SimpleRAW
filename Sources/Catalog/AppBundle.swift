import Foundation

/// What the app is, as the system needs it written: the `Info.plist` of its bundle and the
/// rights that bundle asks for.
///
/// It lives here, next to the importer, because the one thing in it that can drift is the
/// list of file types — and that list is `Importer.importedTypes`, already the answer to
/// "what can this app open". Written by hand in a shell script it would say something else
/// within a month, and the Finder would be offering the app for files it cannot read, or
/// hiding it from files it can. `simpleraw plist` prints these; `scripts/make-app.sh` puts
/// them in the wrapper.
public enum AppBundle {
    public static let identifier = "fr.yoandev.SimpleRAW"
    public static let name = "SimpleRAW"
    public static let executable = "SimpleRAW"
    /// What a person sees in About. The build number follows it.
    public static let version = "0.1.1"
    public static let build = "2"
    /// The oldest macOS this is built against, kept in step with `Package.swift`.
    public static let minimumSystem = "15.0"

    public static var infoPlist: String {
        plist([
            "CFBundleDevelopmentRegion": .string("en"),
            "CFBundleExecutable": .string(executable),
            "CFBundleIdentifier": .string(identifier),
            "CFBundleInfoDictionaryVersion": .string("6.0"),
            "CFBundleName": .string(name),
            "CFBundlePackageType": .string("APPL"),
            "CFBundleShortVersionString": .string(version),
            "CFBundleVersion": .string(build),
            "LSMinimumSystemVersion": .string(minimumSystem),
            // Retina, said outright: without it the window is drawn once and scaled up.
            "NSHighResolutionCapable": .boolean(true),
            // No encryption of our own — the backup speaks HTTPS through the system.
            "ITSAppUsesNonExemptEncryption": .boolean(false),
            "NSHumanReadableCopyright": .string("Yoan Bernabeu"),
            "CFBundleDocumentTypes": .array([.dictionary([
                "CFBundleTypeName": .string("Photograph"),
                // Editor: the app develops what it opens, and keeps the result beside it.
                "CFBundleTypeRole": .string("Editor"),
                "LSHandlerRank": .string("Alternate"),
                "LSItemContentTypes": .array(Importer.importedTypes.map { .string($0.identifier) }),
            ])]),
        ])
    }

    /// The sandbox and the three things the app cannot do without: reaching an S3 server,
    /// opening what a person chose, and the Keychain group the backup files its keys under.
    /// Nothing that lets it out of a hardened runtime — see `AppBundleTests`.
    public static var entitlements: String {
        plist([
            "com.apple.security.app-sandbox": .boolean(true),
            // Outgoing only: the app is a client of an object store, never a server.
            "com.apple.security.network.client": .boolean(true),
            // Only what the person picks in a panel, and the library they chose, which is
            // kept as a security-scoped bookmark rather than as a path.
            "com.apple.security.files.user-selected.read-write": .boolean(true),
        ])
    }

    // MARK: - Writing one

    /// The little of the format that is needed: a property list is XML, and one written by
    /// hand goes wrong quietly. Only the three kinds of value used above.
    enum Value {
        case string(String)
        case boolean(Bool)
        case array([Value])
        case dictionary([String: Value])

        func xml(indent: String) -> String {
            switch self {
            case .string(let text): "\(indent)<string>\(Value.escaped(text))</string>"
            case .boolean(let flag): "\(indent)<\(flag)/>"
            case .array(let values):
                ([indent + "<array>"] + values.map { $0.xml(indent: indent + "\t") } + [indent + "</array>"])
                    .joined(separator: "\n")
            case .dictionary(let pairs):
                ([indent + "<dict>"] + Value.rows(of: pairs, indent: indent + "\t") + [indent + "</dict>"])
                    .joined(separator: "\n")
            }
        }

        /// Sorted, so that the same app produces the same file twice: a wrapper that differs
        /// from one build to the next is a wrapper nobody can compare.
        static func rows(of pairs: [String: Value], indent: String) -> [String] {
            pairs.sorted { $0.key < $1.key }.flatMap { key, value in
                ["\(indent)<key>\(escaped(key))</key>", value.xml(indent: indent)]
            }
        }

        static func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
    }

    static func plist(_ pairs: [String: Value]) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(Value.rows(of: pairs, indent: "\t").joined(separator: "\n"))
        </dict>
        </plist>

        """
    }
}
