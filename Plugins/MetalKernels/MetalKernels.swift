import Foundation
import PackagePlugin

/// Compiles the Core Image kernels of a target into one `.metallib`, which the engine loads
/// at run time. The compiler ships with Xcode's Metal toolchain, not with the Command Line
/// Tools: where it is missing, no library is produced and the stages that need one say so.
@main
struct MetalKernels: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }
        let sources = target.sourceFiles.filter { $0.url.lastPathComponent.hasSuffix(".ci.metal") }.map(\.url)
        guard !sources.isEmpty else { return [] }
        let output = context.pluginWorkDirectoryURL.appending(path: "CoreImageKernels.metallib")
        let script = context.package.directoryURL.appending(path: "scripts/build-metallib.sh")
        return [
            .buildCommand(
                displayName: "Compiling \(sources.count) Core Image kernel(s)",
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [script.path(), output.path()] + sources.map { $0.path() },
                inputFiles: sources + [script],
                outputFiles: [output]
            ),
        ]
    }
}
