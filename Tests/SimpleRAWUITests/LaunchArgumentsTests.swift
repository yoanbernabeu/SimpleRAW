import Foundation
import Testing
@testable import SimpleRAWUI

@Suite struct LaunchArgumentsTests {
    let arguments = LaunchArguments(["/path/to/SimpleRAWApp", "-library", "/tmp/lib", "-crop", "YES", "-zoom", "NO", "-file"])

    @Test func readsValuesByKey() {
        #expect(arguments.value(for: "library") == "/tmp/lib")
        #expect(arguments.url(for: "library") == URL(fileURLWithPath: "/tmp/lib"))
        #expect(arguments.value(for: "look") == nil)
    }

    @Test func aKeyWithoutAValueIsIgnored() {
        #expect(arguments.value(for: "file") == nil)
    }

    @Test func flagsFollowTheDefaultsConvention() {
        #expect(arguments.flag("crop"))
        #expect(!arguments.flag("zoom"))
        #expect(!arguments.flag("masks"))
    }

    /// `-crop -zoom YES` must not take `-zoom` for the value of `-crop`.
    @Test func anotherKeyIsNotAValue() {
        let arguments = LaunchArguments(["app", "-crop", "-zoom", "YES"])
        #expect(arguments.value(for: "crop") == nil)
        #expect(arguments.flag("zoom"))
    }
}

/// The shipped app answers none of them: a library, a file and a look of someone else's
/// choosing, in an app that is meant to open only what its owner picked.
@Suite struct SandboxedLaunchArgumentsTests {
    @Test func aSandboxedAppTakesNoArguments() {
        let arguments = ["SimpleRAW", "-library", "/tmp/elsewhere", "-crop", "YES"]
        #expect(LaunchArguments(arguments, isSandboxed: false).url(for: "library")?.path == "/tmp/elsewhere")
        #expect(LaunchArguments(arguments, isSandboxed: true).url(for: "library") == nil)
        #expect(LaunchArguments(arguments, isSandboxed: true).flag("crop") == false)
    }
}
