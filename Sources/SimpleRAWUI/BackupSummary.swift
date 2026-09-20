import Backup
import Foundation

/// What a run, a restore or a verification found, in a sentence or two for the settings
/// window. The interface is in English, numbers included.
enum BackupSummary {
    /// - Parameter firstKey: empty when the store itself failed, before any file.
    static func failure(count: Int, firstKey: String, firstError: any Error) -> String {
        let reason = sentence(firstError.localizedDescription)
        guard !firstKey.isEmpty else { return "The storage could not be reached. \(reason)" }
        // An error of the backup itself already names its file.
        let detail = firstError is BackupError ? reason : "\(firstKey): \(reason)"
        return "\(counted(count, "file")) could not be backed up. \(detail)"
    }

    /// Everything came back, and every original is what the catalog says it is.
    static func isIntact(_ report: RestoreReport) -> Bool {
        report.corrupted.isEmpty && report.missing.isEmpty && report.failures.isEmpty
    }

    static func restore(_ report: RestoreReport, folder: String) -> String {
        restore(
            downloaded: report.downloaded, damagedOrMissing: report.corrupted.count + report.missing.count,
            failures: report.failures.map { ($0.key, $0.reason) }, folder: folder
        )
    }

    static func restore(downloaded: Int, damagedOrMissing: Int, failures: [(key: String, reason: String)], folder: String) -> String {
        var sentences = ["\(counted(downloaded, "file")) restored to “\(folder)”."]
        if damagedOrMissing > 0 {
            sentences.append("\(counted(damagedOrMissing, "original")) \(damagedOrMissing == 1 ? "is" : "are") damaged or missing.")
        }
        if let first = failures.first {
            sentences.append("\(counted(failures.count, "file")) could not be downloaded (\(first.key): \(first.reason)).")
        }
        if damagedOrMissing == 0, failures.isEmpty { sentences.append("Every original was checked and is intact.") }
        return sentences.joined(separator: " ")
    }

    static func verification(_ report: VerificationReport) -> String {
        guard !report.isSound else { return "All \(counted(report.checked, "file")) are in your backup." }
        let differing = report.sizeMismatches.count + report.fingerprintMismatches.count
        let troubled = report.missing.count + differing + report.unverified.count
        var findings: [String] = []
        if !report.missing.isEmpty { findings.append("\(number(report.missing.count)) \(report.missing.count == 1 ? "is" : "are") missing") }
        if differing > 0 { findings.append("\(number(differing)) \(differing == 1 ? "differs" : "differ") from your library") }
        if !report.unverified.isEmpty { findings.append("\(number(report.unverified.count)) could not be checked") }
        return "\(number(troubled)) of \(counted(report.checked, "file")) \(troubled == 1 ? "needs" : "need") attention: \(findings.joined(separator: ", ")). Back Up Now sends again what is missing."
    }

    /// How far a long job is, for the line next to its button.
    static func progress(_ progress: BackupSession.JobProgress) -> String {
        guard progress.total > 0 else {
            return progress.job == .verify ? "Reading what your backup holds…" : "Looking for your backup…"
        }
        let verb = progress.job == .verify ? "Checking" : "Restoring"
        return "\(verb) \(number(min(progress.done + 1, progress.total))) of \(number(progress.total))…"
    }

    static func counted(_ count: Int, _ noun: String) -> String {
        "\(number(count)) \(noun)\(count == 1 ? "" : "s")"
    }

    static func number(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    private static func sentence(_ text: String) -> String {
        text.hasSuffix(".") ? text : text + "."
    }
}
