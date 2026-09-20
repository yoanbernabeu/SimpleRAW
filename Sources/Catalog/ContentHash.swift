import CryptoKit
import Foundation

/// SHA-256 as the library writes it everywhere: lowercase hexadecimal. How an import
/// recognizes a file it already has, and how a backup checks what it restored.
public enum ContentHash {
    public static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var text = [UInt8]()
        for byte in bytes {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: text, as: UTF8.self)
    }

    public static func sha256(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// Streamed: RAW files are tens of megabytes, a card holds hundreds of them.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }
}

/// Reads a file once, to copy it and to fingerprint it: a memory card is the slow end of an
/// import, and the fingerprint is then that of the bytes that were written, whatever happens
/// to the source afterwards.
enum HashingCopy {
    typealias Write = (FileHandle, Data) throws -> Void

    /// - Parameter write: how a chunk reaches the disk, for tests to fill it up.
    /// - Returns: the SHA-256 of what was copied.
    /// - Throws: `ImportError.notARegularFile` for a link, a folder or a device; the link is
    ///   not followed. Whatever fails, no partial `destination` is left behind.
    static func copy(_ source: URL, to destination: URL, chunkSize: Int = 1 << 20, write: Write = { try $0.write(contentsOf: $1) }) throws -> String {
        // Checked on the open file, not on a path that could be swapped in between.
        let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw ImportError.notARegularFile }
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: source.path, NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
        }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { throw ImportError.notARegularFile }

        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        do {
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var hasher = SHA256()
            while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
                try write(output, chunk)
            }
            // On the disk before the card can be formatted.
            try output.synchronize()
            return ContentHash.hex(hasher.finalize())
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
