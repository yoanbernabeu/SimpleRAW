import AppKit
import Backup
import Foundation
import Testing
@testable import SimpleRAWUI

@Suite struct BackupSummaryTests {
    private struct Busy: LocalizedError {
        var errorDescription: String? { "The server is busy" }
    }

    @Test func aFailedRunNamesWhatFailedOnce() {
        let one = BackupSummary.failure(count: 1, firstKey: "Originals/a.DNG", firstError: Busy())
        #expect(one == "1 file could not be backed up. Originals/a.DNG: The server is busy.")

        // An error of the backup itself already names its file.
        let two = BackupSummary.failure(count: 2, firstKey: "Originals/link.DNG", firstError: BackupError.linkNotBackedUp("Originals/link.DNG"))
        #expect(two.hasPrefix("2 files could not be backed up. Originals/link.DNG is a link"))

        // No key: the store itself did not answer.
        #expect(BackupSummary.failure(count: 1, firstKey: "", firstError: Busy()) == "The storage could not be reached. The server is busy.")
    }

    @Test func aRestoreSaysWhatCameBackAndWhatDidNot() {
        let clean = BackupSummary.restore(downloaded: 1200, damagedOrMissing: 0, failures: [], folder: "Restored")
        #expect(clean == "1,200 files restored to “Restored”. Every original was checked and is intact.")

        let text = BackupSummary.restore(downloaded: 1, damagedOrMissing: 2, failures: [("Originals/c.DNG", "timed out"), ("Originals/d.DNG", "timed out")], folder: "Restored")
        #expect(text.hasPrefix("1 file restored to “Restored”."))
        #expect(text.contains("2 originals are damaged or missing.") && text.contains("2 files could not be downloaded (Originals/c.DNG: timed out)."))
        #expect(!text.contains("intact"))
    }

    @Test func aVerificationSaysWhetherTheBackupCanBeTrusted() {
        var report = VerificationReport(checked: 1200)
        #expect(BackupSummary.verification(report) == "All 1,200 files are in your backup.")

        report.withoutFingerprint = ["Originals/old.DNG"]
        #expect(BackupSummary.verification(report).hasPrefix("All 1,200 files are in your backup."))

        report.missing = ["Originals/a.DNG", "Originals/b.DNG"]
        report.fingerprintMismatches = ["Originals/c.DNG"]
        report.unverified = ["Originals/d.DNG"]
        let text = BackupSummary.verification(report)
        #expect(text.hasPrefix("4 of 1,200 files need attention"))
        #expect(text.contains("2 are missing") && text.contains("1 differs") && text.contains("1 could not be checked"))
        #expect(text.hasSuffix("Back Up Now sends again what is missing."))

        var single = VerificationReport(checked: 2)
        single.missing = ["Originals/a.DNG"]
        #expect(BackupSummary.verification(single).hasPrefix("1 of 2 files needs attention: 1 is missing."))
    }

    @Test func aLongJobSaysHowFarItIs() {
        #expect(BackupSummary.progress(.init(job: .verify)) == "Reading what your backup holds…")
        #expect(BackupSummary.progress(.init(job: .verify, done: 11, total: 1200)) == "Checking 12 of 1,200…")
        #expect(BackupSummary.progress(.init(job: .restore, done: 1200, total: 1200)) == "Restoring 1,200 of 1,200…")
    }
}

@MainActor
@Suite struct BackupStatusLabelTests {
    nonisolated static let statuses: [BackupSession.Status] = [.notConfigured, .disabled, .idle, .running(done: 1, total: 3), .upToDate(Date(), uploaded: 2), .failed("No")]

    /// A cloud says iCloud, which this is not: the backup goes to a drive of one's own.
    @Test(arguments: statuses)
    func everyStatusHasAnIconThatExistsAndIsNotACloud(status: BackupSession.Status) {
        let icon = BackupStatusLabel(status: status).icon
        #expect(!icon.contains("cloud"))
        #expect(NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil)
    }

    @Test func countsAreSaidWithoutParentheses() {
        #expect(BackupStatusLabel(status: .running(done: 0, total: 3)).text == "Backing up 1 of 3…")
        #expect(BackupStatusLabel(status: .upToDate(Date(), uploaded: 1)).text.hasSuffix("1 new file"))
        #expect(BackupStatusLabel(status: .upToDate(Date(), uploaded: 2)).text.hasSuffix("2 new files"))
    }
}
