import Foundation
import Darwin

struct AmpCommandRequest: Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let timeout: TimeInterval
    let outputLimit: Int
}

struct AmpCommandResult: Equatable, Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
}

struct AmpCommandExecutor: Sendable {
    enum Error: Swift.Error, Equatable {
        case timedOut
    }

    func execute(_ request: AmpCommandRequest) async throws -> AmpCommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = request.environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutTask = drain(stdoutPipe.fileHandleForReading, retaining: request.outputLimit)
        let stderrTask = drain(stderrPipe.fileHandleForReading, retaining: request.outputLimit)

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            _ = await stdoutTask.value
            _ = await stderrTask.value
            throw error
        }

        do {
            try await withTaskCancellationHandler {
                try await wait(for: process, timeout: request.timeout)
            } onCancel: {
                terminateWithEscalation(process)
            }
        } catch {
            terminateWithEscalation(process)
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            _ = await stdoutTask.value
            _ = await stderrTask.value
            throw error
        }

        let stdout = await stdoutTask.value
        let stderr = await stderrTask.value
        try Task.checkCancellation()
        return AmpCommandResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    private func drain(_ handle: FileHandle, retaining limit: Int) -> Task<Data, Never> {
        Task.detached {
            var retained = Data()
            let limit = max(0, limit)
            while let chunk = try? handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                if retained.count < limit {
                    retained.append(chunk.prefix(limit - retained.count))
                }
            }
            return retained
        }
    }

    private func wait(for process: Process, timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    process.terminationHandler = { _ in continuation.resume() }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(max(0, timeout)))
                if process.isRunning {
                    terminateWithEscalation(process)
                }
                throw Error.timedOut
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}

private func terminateWithEscalation(_ process: Process) {
    guard process.isRunning else { return }
    let processIdentifier = process.processIdentifier
    process.terminate()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
        if process.isRunning {
            kill(processIdentifier, SIGKILL)
        }
    }
}
