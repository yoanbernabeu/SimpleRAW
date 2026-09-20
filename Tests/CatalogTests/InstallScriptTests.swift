import Foundation
import Testing

/// The installer, run for real rather than read. It is the first thing a stranger executes, in
/// `sh`, off a pipe, and a mistake in it is a project that cannot be installed at all — which is
/// exactly what happened, twice, in a script nothing was watching.
///
/// `curl` is stubbed, so nothing here reaches the network, and the destination is a folder of the
/// test's own: `/Applications` is never touched. Everything else is the script as published.
@Suite struct InstallScriptTests {
    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts/install.sh")

    private struct Run {
        let status: Int32
        let output: String
        let destination: URL
    }

    /// Runs the installer under `/bin/sh` — the shell the published command pipes into, which on
    /// macOS is bash 3.2 and not the zsh of a terminal — against a `curl` that answers with
    /// `release`, and, when `archive` is asked for, with a real zip holding a real (if empty)
    /// `SimpleRAW.app`, quarantined the way anything off the internet is. Standard error is
    /// folded in: what a user sees is one stream.
    ///
    /// `LANG` is part of the environment on purpose. A shell in the `C` locale reads a byte above
    /// 127 as punctuation and a shell in a UTF-8 one reads it as a letter, which is the whole
    /// difference between a working installer and a broken one here; every terminal a user opens
    /// is in the second case, so the test is too.
    private func install(release: String, archive: Bool = false, over leftover: String? = nil, then check: (Run) throws -> Void) throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("install-\(UUID().uuidString)")
        let destination = sandbox.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        if let leftover {
            let old = destination.appendingPathComponent("SimpleRAW.app/Contents/MacOS")
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
            try "an older version".write(to: old.appendingPathComponent(leftover), atomically: true, encoding: .utf8)
        }

        let zip = archive ? try quarantinedArchive(in: sandbox) : nil
        try writeStubCurl(in: sandbox, release: release, archive: zip)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [Self.script.path]
        process.environment = [
            "PATH": "\(sandbox.path):/usr/bin:/bin",
            "HOME": sandbox.path,
            "LANG": "en_US.UTF-8",
            "SIMPLERAW_REPOSITORY": "acme/Widget",
            "SIMPLERAW_DESTINATION": destination.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // Inside the closure, because what the installer wrote is under the sandbox the `defer`
        // above is about to take away.
        try check(Run(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self), destination: destination))
    }

    private func writeStubCurl(in sandbox: URL, release: String, archive: URL?) throws {
        let curl = sandbox.appendingPathComponent("curl")
        try """
        #!/bin/sh
        # Stands in for curl: prints the release, or hands over the archive when asked for a file.
        out=
        while [ $# -gt 0 ]; do
        	[ "$1" = "-o" ] && out=$2
        	shift
        done
        if [ -z "$out" ]; then
        	cat <<'RELEASE'
        \(release)
        RELEASE
        	exit 0
        fi
        [ -f "\(archive?.path ?? "")" ] || exit 1
        # ditto, not cp: what is being carried is the quarantine flag, an extended attribute.
        exec ditto "\(archive?.path ?? "")" "$out"

        """.write(to: curl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)
    }

    /// A `SimpleRAW.zip` as a browser would leave it on the disk: an app bundle inside, and the
    /// quarantine flag on the archive, which `ditto -x -k` then puts on what comes out of it.
    private func quarantinedArchive(in sandbox: URL) throws -> URL {
        let app = sandbox.appendingPathComponent("build/SimpleRAW.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try "not an executable".write(to: app.appendingPathComponent("Contents/MacOS/SimpleRAW"), atomically: true, encoding: .utf8)

        let zip = sandbox.appendingPathComponent("SimpleRAW.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, zip.path])
        try run("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0081;00000000;Safari;", zip.path])
        return zip
    }

    @discardableResult private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func release(asset: String) -> String {
        #"{"assets": [{"browser_download_url": "\#(asset)"}]}"#
    }

    /// The regression this file was written for. `"$repository…"` reads as a variable named
    /// `repository` followed by an ellipsis to a human, and to bash 3.2 in a UTF-8 locale as a
    /// variable whose name runs into the first byte of that ellipsis: under `set -u` the
    /// installer died on its own first message, before downloading anything. A name is closed
    /// with braces when what follows it is not plainly punctuation.
    @Test func itSaysWhichRepositoryItIsLookingIn() throws {
        try install(release: "{}") { run in
            #expect(run.output.contains("Looking for the latest release of acme/Widget"))
            #expect(!run.output.contains("unbound variable"))
        }
    }

    /// A release with no archive in it is the one failure the installer can meet before it has
    /// touched the disk, and it has to be named: silence here reads as a successful install.
    @Test func itStopsWhenTheReleaseHoldsNoArchive() throws {
        try install(release: #"{"assets": []}"#) { run in
            #expect(run.status != 0)
            #expect(run.output.contains("No SimpleRAW.zip in the latest release of acme/Widget"))
        }
    }

    /// The release notes are the README, and the README talks about `SimpleRAW.zip` — so the
    /// answer to "which link is the download" cannot be "the first one GitHub happens to print".
    /// Only a release asset is an asset, and the notes here name a decoy before it.
    @Test func itDownloadsTheReleaseAssetAndNotALinkFromTheNotes() throws {
        try install(release: """
            {"body": "Or download https://example.com/notes/SimpleRAW.zip by hand.",
             "assets": [{"browser_download_url": \
            "https://github.com/acme/Widget/releases/download/v1.2.3/SimpleRAW.zip"}]}
            """) { run in
            #expect(run.output.contains("Downloading https://github.com/acme/Widget/releases/download/v1.2.3/SimpleRAW.zip"))
            #expect(!run.output.contains("example.com/notes"))
        }
    }

    /// The whole of it, end to end: an archive is fetched, unpacked, put where it belongs, and
    /// the quarantine flag taken off — the last being the step that decides whether the app opens
    /// at all, since it is signed ad-hoc and Gatekeeper refuses anything downloaded without it.
    @Test func itInstallsTheAppAndTakesTheQuarantineFlagOff() throws {
        try install(release: release(asset: "https://example.invalid/releases/download/v1/SimpleRAW.zip"), archive: true) { run in
            let installed = run.destination.appendingPathComponent("SimpleRAW.app")
            #expect(run.status == 0, "the installer failed: \(run.output)")
            #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("Contents/MacOS/SimpleRAW").path))
            #expect(run.output.contains("Installed \(installed.path)"))

            let quarantine = try self.run("/usr/bin/xattr", ["-p", "com.apple.quarantine", installed.path])
            #expect(quarantine.contains("No such xattr"), "the app is still quarantined: \(quarantine)")
        }
    }

    /// Running the installer again is the ordinary way to update, and an app bundle is a folder:
    /// copied *into* the old one rather than over it, a new version would inherit every file the
    /// last one left behind. The bundle is removed first, which is what this asks about.
    @Test func itReplacesAnAppThatIsAlreadyThere() throws {
        try install(
            release: release(asset: "https://example.invalid/releases/download/v1/SimpleRAW.zip"),
            archive: true,
            over: "PluginFromAnOlderVersion"
        ) { run in
            let installed = run.destination.appendingPathComponent("SimpleRAW.app")
            #expect(run.status == 0, "the installer failed: \(run.output)")
            #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("Contents/MacOS/SimpleRAW").path))
            #expect(!FileManager.default.fileExists(atPath: installed.appendingPathComponent("Contents/MacOS/PluginFromAnOlderVersion").path))
        }
    }
}
