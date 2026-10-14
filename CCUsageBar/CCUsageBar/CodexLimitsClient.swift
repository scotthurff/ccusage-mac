import Foundation
import os

// Reads current Codex account limits from the installed CLI's app-server,
// reusing its ChatGPT login. Read-only: it initializes, reads the account and
// its rate limits, then closes the server. It never starts a model turn.

// Byte pipes to one `codex app-server` process. Injectable for tests.
protocol CodexTransport: AnyObject, Sendable {
    // Launches the server. Output arrives in chunks; the stream ends when
    // output closes or the process exits.
    func start() throws -> AsyncStream<Data>
    func write(_ data: Data)
    // Closes input and stops the process. The client calls it exactly once.
    func shutdown()
}

enum CodexReadFailure: Error, Equatable {
    case binaryNotFound
    case launchFailed
    case notSignedIn
    case unsupportedLogin
    case requestFailed(String)
    case noQuotas
    case processExited
    case timedOut
    case cancelled
}

struct CodexLimitsReading: Equatable {
    var observation: QuotaObservation
    var accountKey: String?
}

actor CodexLimitsClient: QuotaCollector {
    static let source = "codex-app-server"
    // The account-wide bucket. Every other bucket is its own separate limit.
    static let mainLimitId = "codex"
    private static let logger = Logger(subsystem: "com.ccusagebar", category: "codexlimits")
    private static let pathKey = "codexBinaryPath"

    private let timeout: Duration
    private let now: @Sendable () -> Date
    private let injectedTransport: (@Sendable () async -> CodexTransport?)?
    private var resolvedPath: String?

    init(timeout: Duration = .seconds(15),
         now: @escaping @Sendable () -> Date = { Date() },
         makeTransport: (@Sendable () async -> CodexTransport?)? = nil) {
        self.timeout = timeout
        self.now = now
        self.injectedTransport = makeTransport
    }

    func collect() async -> QuotaCollectionResult {
        switch await read() {
        case .success(let reading):
            return QuotaCollectionResult(accountKey: reading.accountKey, observation: reading.observation)
        case .failure(let failure):
            Self.logger.error("Codex limits read failed: \(String(describing: failure))")
            return QuotaCollectionResult(accountKey: nil, observation: nil)
        }
    }

    // The whole operation, including finding the binary, is bounded by the
    // timeout. Cancellation and timeout both stop the server.
    func read() async -> Result<CodexLimitsReading, CodexReadFailure> {
        let timeout = self.timeout
        return await withTaskGroup(of: Result<CodexLimitsReading, CodexReadFailure>.self) { group in
            group.addTask { await self.readUnbounded() }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .failure(.timedOut)
                } catch {
                    return .failure(.cancelled)
                }
            }
            let first = await group.next() ?? .failure(.cancelled)
            group.cancelAll()
            return first
        }
    }

    private func readUnbounded() async -> Result<CodexLimitsReading, CodexReadFailure> {
        let made: CodexTransport?
        if let injectedTransport {
            made = await injectedTransport()
        } else {
            made = await defaultTransport()
        }
        guard let transport = made else {
            return .failure(Task.isCancelled ? .cancelled : .binaryNotFound)
        }
        defer { transport.shutdown() }
        if Task.isCancelled { return .failure(.cancelled) }
        let output: AsyncStream<Data>
        do {
            output = try transport.start()
        } catch {
            Self.logger.error("Failed to launch codex app-server: \(error.localizedDescription)")
            return .failure(.launchFailed)
        }
        return await converse(transport, MessageReader(output))
    }

    private func converse(_ transport: CodexTransport, _ reader: MessageReader) async -> Result<CodexLimitsReading, CodexReadFailure> {
        func request(_ id: Int, _ method: String, _ params: [String: Any]) async -> Result<[String: Any], CodexReadFailure> {
            transport.write(Self.line(["id": id, "method": method, "params": params]))
            return await reader.response(to: id, method: method)
        }

        // Never send `supportsLunaReserve`: it lets the backend record experiment exposure.
        if case .failure(let failure) = await request(1, "initialize", ["clientInfo": ["name": "ccusagebar", "version": "1.0"]]) {
            return .failure(failure)
        }
        transport.write(Self.line(["method": "initialized"]))

        switch await request(2, "account/read", ["refreshToken": false]) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let result):
            guard let account = result["account"] as? [String: Any] else { return .failure(.notSignedIn) }
            guard account["type"] as? String == "chatgpt" else { return .failure(.unsupportedLogin) }
        }

        // Detailed reset credits carry their expiry dates.
        switch await request(3, "account/rateLimits/read", ["excludeResetCreditDetails": false]) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let result):
            guard let reading = Self.parseRateLimits(result, observedAt: now()) else { return .failure(.noQuotas) }
            return .success(reading)
        }
    }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        return data
    }

    // MARK: - Response decoding

    static func parseRateLimits(_ result: [String: Any], observedAt: Date) -> CodexLimitsReading? {
        // Prefer the per-bucket map; the legacy single view only when the map is absent.
        var buckets: [(id: String, snapshot: [String: Any])] = []
        if let map = result["rateLimitsByLimitId"] as? [String: Any] {
            buckets = map.compactMap { key, value in (value as? [String: Any]).map { (key, $0) } }
        } else if let single = result["rateLimits"] as? [String: Any] {
            buckets = [(mainLimitId, single)]
        }
        buckets.sort { ($0.id == mainLimitId ? "" : $0.id) < ($1.id == mainLimitId ? "" : $1.id) }

        var windows: [QuotaWindow] = []
        for bucket in buckets {
            for window in bucketWindows(id: bucket.id, bucket.snapshot) where !windows.contains(where: { $0.id == window.id }) {
                windows.append(window)
            }
        }
        guard !windows.isEmpty else { return nil }

        let main = buckets.first { $0.id == mainLimitId }?.snapshot
        let balance = ((main?["credits"] as? [String: Any])?["balance"] as? String).flatMap(Double.init)
        let observation = QuotaObservation(
            source: source, observedAt: observedAt, windows: windows,
            resetCredits: resetCredits(result["rateLimitResetCredits"], after: observedAt),
            creditBalance: balance.flatMap { $0.isFinite ? $0 : nil })
        let accountKey = (result["accountId"] as? String).flatMap { $0.isEmpty ? nil : QuotaAccountKey.make(.codex, [$0]) }
        return CodexLimitsReading(observation: observation, accountKey: accountKey)
    }

    // Windows are classified by their reported length, never by position.
    private static func bucketWindows(id: String, _ snapshot: [String: Any]) -> [QuotaWindow] {
        let isMain = id == mainLimitId
        let name = (snapshot["limitName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
        var found: [(position: String, minutes: Int?, used: Double, resetsAt: Date?)] = []
        for position in ["primary", "secondary"] {
            guard let raw = snapshot[position] as? [String: Any],
                  let used = QuotaValues.percent(raw["usedPercent"]) else { continue }
            let minutes = QuotaValues.number(raw["windowDurationMins"]).map(\.intValue).flatMap { $0 > 0 ? $0 : nil }
            // Two positions reporting the same length are one window.
            if let minutes, found.contains(where: { $0.minutes == minutes }) { continue }
            found.append((position, minutes, used, QuotaValues.date(unixSeconds: raw["resetsAt"])))
        }
        return found.map { window in
            let length = QuotaValues.durationLabel(window.minutes)
            let label = isMain ? length : (found.count == 1 ? name : "\(name) \(length.lowercased())")
            return QuotaWindow(id: "codex:\(id):\(window.minutes.map(String.init) ?? window.position)",
                               label: label, durationMinutes: window.minutes, usedPercent: window.used,
                               resetsAt: window.resetsAt, scope: isMain ? .provider : .model)
        }
    }

    private static func resetCredits(_ value: Any?, after observedAt: Date) -> ResetCreditsInfo? {
        guard let summary = value as? [String: Any],
              let count = QuotaValues.number(summary["availableCount"])?.intValue, count >= 0 else { return nil }
        let expiries = (summary["credits"] as? [[String: Any]] ?? [])
            .filter { $0["status"] as? String == "available" }
            .compactMap { QuotaValues.date(unixSeconds: $0["expiresAt"]) }
            .filter { $0 > observedAt }
        return ResetCreditsInfo(available: count, nextExpiry: expiries.min())
    }

    // MARK: - Finding and launching the CLI

    private func defaultTransport() async -> CodexTransport? {
        guard let path = await resolvePath() else {
            Self.logger.info("codex binary not found; Codex limits unavailable")
            return nil
        }
        return CodexProcessTransport(executable: URL(fileURLWithPath: path))
    }

    // Resolved independently from ccusage. The login shell defines a `codex`
    // function, so `which` would print its body; `whence -p` prints the path.
    private func resolvePath() async -> String? {
        if let resolvedPath, FileManager.default.isExecutableFile(atPath: resolvedPath) { return resolvedPath }
        if let cached = UserDefaults.standard.string(forKey: Self.pathKey),
           FileManager.default.isExecutableFile(atPath: cached) {
            resolvedPath = cached
            return cached
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shellPath = await Self.whence()
        let candidates = [shellPath, "\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        guard let path = candidates.compactMap({ $0 }).first(where: {
            $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0)
        }) else { return nil }
        resolvedPath = path
        UserDefaults.standard.set(path, forKey: Self.pathKey)
        Self.logger.info("Resolved codex binary at: \(path)")
        return path
    }

    private static func whence() async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "whence -p codex"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                process.terminationHandler = { proc in
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: proc.terminationStatus == 0 && !output.isEmpty ? output : nil)
                }
                do {
                    try process.run()
                    // Covers a cancellation that arrived just before launch.
                    if Task.isCancelled { process.terminate() }
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

// MARK: - Line framing

// Joins output fragments and splits batches into whole lines.
struct LineBuffer {
    private var pending = Data()

    mutating func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = Data(pending[pending.startIndex..<newline])
            pending = Data(pending[pending.index(after: newline)...])
            if line.last == 0x0D { line.removeLast() }
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}

// Pulls JSON messages off the output and matches responses to request ids.
// Notifications, server requests, and unrelated responses are skipped.
private final class MessageReader: @unchecked Sendable {
    private var iterator: AsyncStream<Data>.AsyncIterator
    private var buffer = LineBuffer()
    private var pending: [Data] = []

    init(_ output: AsyncStream<Data>) {
        iterator = output.makeAsyncIterator()
    }

    func response(to id: Int, method: String) async -> Result<[String: Any], CodexReadFailure> {
        while true {
            if !pending.isEmpty {
                let line = pending.removeFirst()
                guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      message["method"] == nil,
                      QuotaValues.number(message["id"])?.intValue == id else { continue }
                if message["error"] != nil { return .failure(.requestFailed(method)) }
                return .success(message["result"] as? [String: Any] ?? [:])
            }
            guard let chunk = await iterator.next() else {
                return .failure(Task.isCancelled ? .cancelled : .processExited)
            }
            pending += buffer.append(chunk)
        }
    }
}

// MARK: - The real subprocess

final class CodexProcessTransport: CodexTransport, @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private var isShutDown = false

    var isRunning: Bool { process.isRunning }

    init(executable: URL, arguments: [String] = ["app-server"]) {
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = NSHomeDirectory()
        environment["PATH"] = "\(executable.deletingLastPathComponent().path):/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    func start() throws -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        lock.withLock { self.continuation = continuation }
        // A write after the server exits must fail, not raise SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        // Drained and discarded so a chatty log can't block the server.
        errors.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        process.terminationHandler = { _ in continuation.finish() }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            throw error
        }
        return stream
    }

    func write(_ data: Data) {
        let open = lock.withLock { !isShutDown }
        guard open else { return }
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    // Closing input ends the server normally; one that lingers is stopped.
    func shutdown() {
        let continuation = lock.withLock { () -> AsyncStream<Data>.Continuation? in
            guard !isShutDown else { return nil }
            isShutDown = true
            return self.continuation
        }
        continuation?.finish()
        try? input.fileHandleForWriting.close()
        let process = self.process
        guard process.isRunning else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
