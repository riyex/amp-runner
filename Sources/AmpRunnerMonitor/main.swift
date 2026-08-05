import Dispatch
import Foundation
import AmpRunnerMonitorSupport

#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

let workingDirectoryURL = URL(
    fileURLWithPath: FileManager.default.currentDirectoryPath,
    isDirectory: true
)

do {
    let configuration = try RunnerProcessMonitorConfiguration.parse(
        arguments: Array(CommandLine.arguments.dropFirst()),
        workingDirectoryURL: workingDirectoryURL
    )
    let monitor = RunnerProcessMonitor(configuration: configuration)
    let signalSources = installSignalHandlers(for: monitor)
    let status = monitor.run()
    signalSources.forEach { $0.cancel() }
    exit(status)
} catch {
    FileHandle.standardError.write(
        Data("[amp-runner-monitor] \(error)\n".utf8)
    )
    exit(64)
}

private func installSignalHandlers(for monitor: RunnerProcessMonitor) -> [DispatchSourceSignal] {
    [SIGINT, SIGTERM, SIGHUP].map { signalNumber in
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
        source.setEventHandler {
            monitor.requestStop()
        }
        source.resume()
        return source
    }
}
