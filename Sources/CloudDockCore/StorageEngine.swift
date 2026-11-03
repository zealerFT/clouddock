import Foundation
import Darwin

/// Each command has an independent process and immutable connection environment.
public final class CommandHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var suspended = false
    public init() {}
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let p = process, p.isRunning {
            if suspended { kill(p.processIdentifier, SIGCONT) }
            p.terminate()
        }
    }
    public func pause() {
        lock.lock(); defer { lock.unlock() }
        suspended = true
        if let p = process, p.isRunning { kill(p.processIdentifier, SIGSTOP) }
    }
    public func resume() {
        lock.lock(); defer { lock.unlock() }
        suspended = false
        if let p = process, p.isRunning { kill(p.processIdentifier, SIGCONT) }
    }
    fileprivate func launch(_ p: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        process = p
        try p.run()
        if suspended { kill(p.processIdentifier, SIGSTOP) }
    }
    fileprivate func finish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        process = nil
        return cancelled
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var pending = Data()
    private var overflow = false
    private var lastStats: TransferStats?
    private let secrets: Credentials
    private let progress: ((TransferStats) -> Void)?
    init(secrets: Credentials, progress: ((TransferStats) -> Void)?) { self.secrets = secrets; self.progress = progress }
    func append(_ data: Data, error: Bool) {
        lock.lock()
        var stats: [TransferStats] = []
        if error {
            stderr.append(data)
            if stderr.count > 64 * 1024 { stderr = Data(stderr.suffix(64 * 1024)) }
            pending.append(data)
            while let end = pending.firstIndex(of: 10) {
                let line = pending.subdata(in: 0..<end)
                pending.removeSubrange(0...end)
                if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   let value = json["stats"], let payload = try? JSONSerialization.data(withJSONObject: value),
                   let stat = try? JSONDecoder().decode(TransferStats.self, from: payload) { stats.append(stat); lastStats = stat }
            }
            if pending.count > 128 * 1024 { pending.removeAll() }
        } else if stdout.count + data.count <= 32 * 1024 * 1024 { stdout.append(data) }
        else { overflow = true }
        lock.unlock()
        stats.forEach { progress?($0) }
    }
    func result(status: Int32) throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        if overflow { throw CloudError.message("结果超过 32 MB，请进入更具体的目录后再搜索。") }
        if status != 0 {
            let log = String(data: stderr, encoding: .utf8) ?? ""
            let lines = log.split(separator: "\n").compactMap { line -> String? in
                guard let data = line.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return String(line) }
                if json["stats"] != nil { return nil }
                return json["msg"] as? String
            }
            let message = lines.suffix(6).joined(separator: "\n")
            throw CloudError.message(secrets.redact(message.isEmpty ? "存储服务返回错误（\(status)）。" : message))
        }
        return CommandResult(data: stdout, stats: lastStats)
    }
}

public final class StorageEngine: @unchecked Sendable {
    public let executable: URL
    public let objectListing: ObjectListingClient
    public init(executable: URL? = nil, objectListing: ObjectListingClient = ObjectListingClient()) {
        self.objectListing = objectListing
        if let executable { self.executable = executable }
        else if let path = Bundle.main.url(forResource: "rclone", withExtension: nil), FileManager.default.isExecutableFile(atPath: path.path) { self.executable = path }
        else if let path = ProcessInfo.processInfo.environment["CLOUDDOCK_RCLONE"] { self.executable = URL(fileURLWithPath: path) }
        else { self.executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("vendor/rclone") }
    }
    public func environment(connection: Connection, credentials: Credentials) -> [String: String] {
        // Do not inherit unrelated RCLONE_* or cloud credentials from the launching shell.
        var env: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8"]
        for key in ["HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "no_proxy"] {
            if let value = ProcessInfo.processInfo.environment[key] { env[key] = value }
        }
        let p = "RCLONE_CONFIG_CLOUD_"
        // This client manages objects in existing buckets; never require CreateBucket permission.
        env[p + "NO_CHECK_BUCKET"] = "true"
        if connection.provider == .google {
            env[p + "TYPE"] = "google cloud storage"
            env[p + "SERVICE_ACCOUNT_CREDENTIALS"] = credentials.serviceAccountJSON
            env[p + "PROJECT_NUMBER"] = connection.projectNumber
            if !connection.endpoint.isEmpty { env[p + "ENDPOINT"] = connection.googleAPIEndpoint }
            if connection.isLocalGoogleEndpoint {
                // Local GCS emulators intentionally run without OAuth. This branch
                // only applies to localhost/IP endpoints; hosted GCS keeps credentials.
                env[p + "ANONYMOUS"] = "true"
                if connection.projectNumber.isEmpty || connection.projectNumber.contains(where: { !$0.isNumber }) {
                    env[p + "PROJECT_NUMBER"] = "0"
                }
            }
            env[p + "ENV_AUTH"] = "false"
            env[p + "DIRECTORY_MARKERS"] = "true"
        } else {
            env[p + "TYPE"] = "s3"
            // rclone's AWS preset forces virtual-host routing and AWS-specific upload
            // defaults. Local AWS emulators need its signed S3-compatible preset so
            // FORCE_PATH_STYLE is honored and HTTP directory markers can be uploaded.
            env[p + "PROVIDER"] = connection.provider == .aws && connection.requiresPathStyle ? "Other" : connection.provider.rcloneProvider
            env[p + "ACCESS_KEY_ID"] = credentials.accessKey
            env[p + "SECRET_ACCESS_KEY"] = credentials.secretKey
            env[p + "SESSION_TOKEN"] = credentials.sessionToken
            env[p + "ENDPOINT"] = connection.endpoint
            env[p + "REGION"] = connection.region
            env[p + "ENV_AUTH"] = "false"
            env[p + "FORCE_PATH_STYLE"] = connection.usesPathStyle ? "true" : "false"
            // Keep real folder markers in S3 so that empty folders survive refresh.
            env[p + "DIRECTORY_MARKERS"] = "true"
        }
        return env
    }
    @discardableResult
    public func run(_ arguments: [String], connection: Connection, credentials: Credentials,
                    handle: CommandHandle = CommandHandle(), progress: ((TransferStats) -> Void)? = nil) async throws -> Data {
        try await runResult(arguments, connection: connection, credentials: credentials, handle: handle, progress: progress).data
    }
    public func runResult(_ arguments: [String], connection: Connection, credentials: Credentials,
                          handle: CommandHandle = CommandHandle(), progress: ((TransferStats) -> Void)? = nil) async throws -> CommandResult {
        let env = environment(connection: connection, credentials: credentials)
        let binary = executable
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    let out = Pipe(), err = Pipe()
                    let buffer = OutputBuffer(secrets: credentials, progress: progress)
                    let readers = DispatchGroup()
                    process.executableURL = binary
                    process.arguments = arguments + ["--config", "/dev/null", "--use-json-log", "--stats", "500ms", "--stats-log-level", "NOTICE", "--retries", "3", "--low-level-retries", "5", "--contimeout", "15s", "--timeout", "60s"]
                    process.environment = env
                    process.standardOutput = out; process.standardError = err
                    process.standardInput = FileHandle.nullDevice
                    do {
                        try handle.launch(process)
                        // Separate blocking readers drain both pipes before collecting the result.
                        for (pipe, isError) in [(out, false), (err, true)] {
                            readers.enter()
                            DispatchQueue.global(qos: .utility).async {
                                defer { readers.leave() }
                                while let data = try? pipe.fileHandleForReading.read(upToCount: 8192), !data.isEmpty { buffer.append(data, error: isError) }
                            }
                        }
                        process.waitUntilExit()
                        readers.wait()
                        if handle.finish() { throw CancellationError() }
                        if process.terminationReason == .uncaughtSignal {
                            throw CloudError.message("传输进程被系统终止（信号 \(process.terminationStatus)），请重试；若重复出现，请检查应用签名及系统诊断。")
                        }
                        continuation.resume(returning: try buffer.result(status: process.terminationStatus))
                    } catch {
                        _ = handle.finish()
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: { handle.cancel() })
    }
    public func list(connection: Connection, credentials: Credentials, bucket: String = "", prefix: String = "", recursive: Bool = false, handle: CommandHandle = CommandHandle()) async throws -> [RemoteEntry] {
        var args = ["lsjson", try ObjectPath.remote(bucket: bucket, key: prefix), "--no-mimetype"]
        if recursive { args += ["--recursive"] }
        if bucket.isEmpty { args += ["--dirs-only"] }
        let data = try await run(args, connection: connection, credentials: credentials, handle: handle)
        return try JSONDecoder().decode([RemoteEntry].self, from: data)
    }
    public func makeFolder(connection: Connection, credentials: Credentials, bucket: String, prefix: String, name: String) async throws {
        guard !bucket.isEmpty else { throw CloudError.message("请先进入存储桶。") }
        try ObjectPath.validateComponent(name)
        let target = try ObjectPath.remote(bucket: bucket, key: ObjectPath.join(prefix, name))
        try await run(["mkdir", target], connection: connection, credentials: credentials)
    }
    public func rename(connection: Connection, credentials: Credentials, bucket: String, key: String, newName: String, directory: Bool) async throws {
        try ObjectPath.validateComponent(newName)
        let source = try ObjectPath.remote(bucket: bucket, key: key)
        let targetKey = ObjectPath.join(ObjectPath.parent(key), newName)
        guard key != targetKey else { return }
        let target = try ObjectPath.remote(bucket: bucket, key: targetKey)
        // Caller checks siblings before queueing; immutable prevents replacing changed objects.
        let args = [directory ? "move" : "moveto", source, target, "--immutable"] + (directory ? ["--create-empty-src-dirs", "--delete-empty-src-dirs"] : [])
        try await run(args, connection: connection, credentials: credentials)
    }
    public func remove(connection: Connection, credentials: Credentials, bucket: String, key: String, directory: Bool) async throws {
        guard !bucket.isEmpty, !key.isEmpty else { throw CloudError.message("不允许通过文件删除操作删除整个存储桶。") }
        try await run([directory ? "purge" : "deletefile", try ObjectPath.remote(bucket: bucket, key: key)], connection: connection, credentials: credentials)
    }
}
