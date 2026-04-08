import Foundation
import os

enum CCUsageError: LocalizedError {
    case binaryNotFound
    case processExitFailure(status: Int32)
    case timeout
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "ccusage binary not found. Install with: npm install -g ccusage"
        case .processExitFailure(let status):
            return "ccusage exited with status \(status)"
        case .timeout:
            return "ccusage timed out after 30 seconds"
        case .decodingFailed(let error):
            return "Failed to parse ccusage output: \(error.localizedDescription)"
        }
    }
}

actor CCUsageRunner {
    private static let logger = Logger(subsystem: "com.ccusagebar", category: "runner")

    private var resolvedPath: String?

    func fetchUsage(since: String) async throws -> UsageResponse {
        let binaryPath = try await resolveBinaryPath()
        let nvmBinDir = URL(fileURLWithPath: binaryPath).deletingLastPathComponent().path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["daily", "--json", "--since", since]
        process.environment = [
            "PATH": "\(nvmBinDir):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "NODE_PATH": URL(fileURLWithPath: nvmBinDir).deletingLastPathComponent().appendingPathComponent("lib/node_modules").path
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        Self.logger.info("Running ccusage: \(binaryPath) daily --json --since \(since)")

        // Race: process vs 30-second timeout
        return try await withThrowingTaskGroup(of: UsageResponse.self) { group in
            group.addTask {
                try await self.runProcess(process, stdout: stdoutPipe, stderr: stderrPipe)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                process.terminate()
                throw CCUsageError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func runProcess(_ process: Process, stdout: Pipe, stderr: Pipe) async throws -> UsageResponse {
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { [weak stdout] proc in
                guard let stdout = stdout else {
                    continuation.resume(throwing: CCUsageError.processExitFailure(status: -1))
                    return
                }

                let data = stdout.fileHandleForReading.readDataToEndOfFile()

                guard proc.terminationStatus == 0 else {
                    let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
                    Self.logger.error("ccusage failed (status \(proc.terminationStatus)): \(stderrStr)")
                    continuation.resume(throwing: CCUsageError.processExitFailure(status: proc.terminationStatus))
                    return
                }

                do {
                    let response = try JSONDecoder().decode(UsageResponse.self, from: data)
                    continuation.resume(returning: response)
                } catch {
                    Self.logger.error("JSON decode error: \(error)")
                    continuation.resume(throwing: CCUsageError.decodingFailed(error))
                }
            }

            do {
                try process.run()
            } catch {
                Self.logger.error("Failed to launch ccusage: \(error)")
                continuation.resume(throwing: CCUsageError.binaryNotFound)
            }
        }
    }

    private func resolveBinaryPath() async throws -> String {
        if let path = resolvedPath {
            // Verify it still exists
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
            resolvedPath = nil
        }

        // Check UserDefaults cache
        if let cached = UserDefaults.standard.string(forKey: "ccusageBinaryPath"),
           FileManager.default.fileExists(atPath: cached) {
            resolvedPath = cached
            return cached
        }

        // Resolve via zsh -lc (one-time shell invocation)
        let path = try await resolveViaShell()
        resolvedPath = path
        UserDefaults.standard.set(path, forKey: "ccusageBinaryPath")
        Self.logger.info("Resolved ccusage binary at: \(path)")
        return path
    }

    private func resolveViaShell() async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "which ccusage"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            process.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                guard proc.terminationStatus == 0, !output.isEmpty else {
                    continuation.resume(throwing: CCUsageError.binaryNotFound)
                    return
                }

                continuation.resume(returning: output)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: CCUsageError.binaryNotFound)
            }
        }
    }
}
