import Foundation

/// File names made from text that comes from elsewhere: the name of a look, the template of
/// an export preset, the name of a file on a memory card. The one place where such text is
/// made safe, applied to the **result** of a template, never to its parts.
public enum FileName {
    /// What a macOS file system takes, in UTF-8 bytes of the decomposed name.
    public static let maximumBytes = 255
    /// When even the fallback is no name at all.
    static let lastResort = "Untitled"

    /// `name` as a file name that stays where it is put: separators ("/", ":"), NUL and
    /// control characters become "-", leading dots go (no hidden file, no "." or ".."), and
    /// the name is cut to what a file system takes. What is left of `fallback`, treated the
    /// same way, when nothing is left of `name`.
    ///
    /// Works on Unicode scalars: a "/" followed by a combining mark is a single `Character`
    /// that is not "/", yet the file system sees the separator.
    /// - Parameter reserved: bytes to keep free for what the caller appends: an extension,
    ///   the "-2" of a name already taken.
    public static func sanitized(_ name: String, fallback: String, reserving reserved: Int = 0) -> String {
        cleaned(name, reserved) ?? cleaned(fallback, reserved) ?? lastResort
    }

    /// `text` as it may be printed: a file name from a memory card can hold control characters
    /// that rewrite what a terminal shows, or marks that reverse the reading order and make
    /// "photo‮gnd.exe" read as something else. Each becomes "?".
    public static func displayable(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let category = scalar.properties.generalCategory
            let isUnsafe = category == .control || category == .lineSeparator || category == .paragraphSeparator
                || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
            scalars.append(isUnsafe ? "?" : scalar)
        }
        return String(scalars)
    }

    /// `wanted`, or the same name with "-2", "-3"… if it is taken: nothing is ever written
    /// over a file that is there.
    public static func free(_ wanted: URL) -> URL {
        let (folder, ext) = (wanted.deletingLastPathComponent(), wanted.pathExtension)
        let stem = wanted.deletingPathExtension().lastPathComponent
        var candidate = wanted
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem)-\(number)").appendingPathExtension(ext)
            number += 1
        }
        return candidate
    }

    /// Whether `file` sits right in `folder`, once ".." in its path is resolved.
    ///
    /// Folders are compared with folders: `standardizedFileURL` spells a path that exists and
    /// one that does not differently ("/tmp" for the first, "/private/tmp" for the second),
    /// and the file is yet to be written while its folder usually is there. Comparing the
    /// file's own path made every export to such a folder look like it sat elsewhere.
    public static func isContained(_ file: URL, in folder: URL) -> Bool {
        let name = file.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        return canonical(file.deletingLastPathComponent()) == canonical(folder)
    }

    /// "/private/tmp" and "/tmp" are one folder, which resolving links only finds out when
    /// the folder exists: a batch may be given one it has yet to create.
    private static func canonical(_ folder: URL) -> String {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    /// What a name weighs once handed to the file system, which decomposes it.
    static func fileSystemBytes(_ name: String) -> Int {
        max(name.utf8.count, name.decomposedStringWithCanonicalMapping.utf8.count)
    }

    private static func cleaned(_ name: String, _ reserved: Int) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            let isForbidden = scalar == "/" || scalar == ":" || scalar.properties.generalCategory == .control
            scalars.append(isForbidden ? "-" : scalar)
        }
        let visible = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "." }
        // Dashes, dots and spaces alone are what is left of a name made of nothing else.
        guard visible.unicodeScalars.contains(where: { !"-. ".unicodeScalars.contains($0) }) else { return nil }

        // Cut between characters: half an emoji is not a name. Bytes are counted on the
        // decomposed form, the larger of the two and the one the file system is handed:
        // "é" weighs three bytes there, not two.
        var (result, bytes) = ("", 0)
        for character in visible {
            bytes += fileSystemBytes(String(character))
            guard bytes <= max(maximumBytes - reserved, 1) else { break }
            result.append(character)
        }
        return result.isEmpty ? nil : result
    }
}
