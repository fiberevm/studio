import Foundation
import AppKit

/// AWS Lambda MicroVMs (Firecracker VMs, up to 8 h, suspend/resume) as a Studio sandbox provider.
///
/// Lifecycle goes through the AWS CLI (`aws lambda-microvms …`, your credentials and region). Lambda MicroVMs
/// have no exec API, so the `studio-sandbox` image (Resources/MicroVMAgent, built once by setup.sh) runs a small
/// agent; commands and uploads go to it over the MicroVM's HTTPS endpoint with a short-lived Lambda auth token.
final class AWSMicroVMProvider: SandboxProvider, @unchecked Sendable {
    let id = "aws"
    static let agentPort = 8970
    private let aws: String? = ["/opt/homebrew/bin/aws", "/usr/local/bin/aws", "/usr/bin/aws"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private var d: UserDefaults { .standard }
    var imageArn: String? { d.string(forKey: "sandbox.aws.imageArn").flatMap { $0.isEmpty ? nil : $0 } }
    var imageVersion: String? { d.string(forKey: "sandbox.aws.imageVersion").flatMap { $0.isEmpty ? nil : $0 } }
    var executionRole: String? { d.string(forKey: "sandbox.aws.executionRoleArn").flatMap { $0.isEmpty ? nil : $0 } }
    var region: String? { d.string(forKey: "sandbox.aws.region").flatMap { $0.isEmpty ? nil : $0 } }
    var profile: String? { d.string(forKey: "sandbox.aws.profile").flatMap { $0.isEmpty ? nil : $0 } }

    /// The CLI is there and the Studio image has been set up.
    var installed: Bool { aws != nil && imageArn != nil }
    var cliInstalled: Bool { aws != nil }

    private let lock = NSLock()
    private var tokens: [String: (token: String, expires: Date)] = [:]
    private var endpoints: [String: String] = [:]

    // MARK: CLI

    private func cli(_ args: [String], timeout: TimeInterval = 120) async throws -> [String: Any] {
        guard let aws else { throw SandboxError(message: "The AWS CLI isn't installed (brew install awscli).") }
        var full = args + ["--output", "json"]
        if let region { full += ["--region", region] }
        if let profile { full += ["--profile", profile] }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: aws)
                p.arguments = full
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                if p.terminationStatus != 0 {
                    let msg = String(data: e, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    cont.resume(throwing: SandboxError(message: msg.isEmpty ? "aws \(args.prefix(2).joined(separator: " ")) failed" : msg))
                    return
                }
                let json = (try? JSONSerialization.jsonObject(with: o)) as? [String: Any] ?? [:]
                cont.resume(returning: json)
            }
        }
    }

    private static func state(_ s: String?) -> String {
        switch (s ?? "").uppercased() {
        case "RUNNING": return "running"
        case "SUSPENDED", "SUSPENDING": return "stopped"
        case "PENDING", "RESUMING", "STARTING": return "pending"
        case "TERMINATED", "TERMINATING": return "terminated"
        case "FAILED": return "error"
        default: return (s ?? "unknown").lowercased()
        }
    }

    private func info(_ o: [String: Any]) -> SandboxInfo? {
        guard let id = o["microvmId"] as? String ?? o["id"] as? String else { return nil }
        if let e = o["endpoint"] as? String { lock.withLock { endpoints[id] = e } }
        return SandboxInfo(id: id, name: nil, state: Self.state(o["state"] as? String), type: "microvm", provider: "aws")
    }

    // MARK: SandboxProvider

    func list() async throws -> [SandboxInfo] {
        let r = try await cli(["lambda-microvms", "list-microvms"], timeout: 30)
        let arr = r.values.compactMap { $0 as? [[String: Any]] }.first ?? []
        return arr.compactMap(info).filter { $0.state != "terminated" }
    }

    func create(type: String?, ttlMinutes: Int?, environment: String?) async throws -> SandboxInfo {
        guard let imageArn else { throw SandboxError(message: "Set up the AWS MicroVM image first (Settings → Sandboxes → AWS → Set Up).") }
        let idle = max(60, (ttlMinutes ?? 15) * 60)
        var args = ["lambda-microvms", "run-microvm", "--image-identifier", imageArn,
                    "--idle-policy", "{\"maxIdleDurationSeconds\":\(idle),\"suspendedDurationSeconds\":86400,\"autoResumeEnabled\":true}",
                    "--maximum-duration-in-seconds", "28800"]
        if let v = imageVersion { args += ["--image-version", v] }
        if let role = executionRole { args += ["--execution-role-arn", role] }
        if let r = region {   // shell access for sandbox_terminal
            args += ["--ingress-network-connectors", "arn:aws:lambda:\(r):aws:network-connector:aws-network-connector:SHELL_INGRESS",
                     "arn:aws:lambda:\(r):aws:network-connector:aws-network-connector:HTTP_INGRESS"]
        }
        let r = try await cli(args, timeout: 120)
        guard let s = info(r) else { throw SandboxError(message: "run-microvm returned no id") }
        // Ready = the agent answers (get-microvm state lags; AWS recommends probing the endpoint).
        for _ in 0..<40 {
            if (try? await call(s.id, "GET", "/studio/health", body: nil, timeout: 5)) != nil { break }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        return SandboxInfo(id: s.id, name: nil, state: "running", type: "microvm", provider: "aws")
    }

    func exec(_ id: String, command: String, cwd: String?, timeout: Int, background: Bool) async throws -> Any {
        let body: [String: Any] = ["command": command, "cwd": cwd ?? "", "timeout": timeout, "background": background]
        return try await call(id, "POST", "/studio/exec", body: try JSONSerialization.data(withJSONObject: body),
                              timeout: TimeInterval(timeout == 0 ? 3600 : timeout + 30))
    }

    /// Git-tracked (and untracked, non-ignored) files as a tar.gz, like `boat push`.
    func push(_ id: String, dir: String, to: String?) async throws -> Any {
        let dest = to ?? "/home/user/" + (dir as NSString).lastPathComponent
        let tgz = try await Self.tarball(dir)
        var r = try await call(id, "POST", "/studio/upload?to=" + (dest.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? dest),
                               body: tgz, timeout: 900, contentType: "application/gzip") as? [String: Any] ?? [:]
        r["bytes"] = tgz.count
        return r
    }

    func url(_ id: String, port: Int, isPublic: Bool) async throws -> Any {
        let endpoint = try await endpoint(id)
        let token = try await token(id, ports: [port])
        return ["url": "https://\(endpoint)/",
                "headers": ["X-aws-proxy-auth": token, "X-aws-proxy-port": "\(port)"],
                "note": "Requests need these headers (token valid ≤ 60 min). Browsers can't add them; use curl or a client that sets headers.\(isPublic ? " Lambda MicroVM endpoints are never public." : "")"]
    }

    func stop(_ id: String) async throws -> Any { try await cli(["lambda-microvms", "suspend-microvm", "--microvm-identifier", id]) }
    func resume(_ id: String) async throws -> Any { try await cli(["lambda-microvms", "resume-microvm", "--microvm-identifier", id]) }
    func delete(_ id: String) async throws -> Any { try await cli(["lambda-microvms", "terminate-microvm", "--microvm-identifier", id]) }

    /// Interactive shell over the MicroVM's shell WebSocket (needs websocat).
    func sshCommand(_ id: String) -> String {
        let ep = lock.withLock { endpoints[id] } ?? "\(id).lambda-microvm.\(region ?? "us-east-1").on.aws"
        var awsArgs = "--microvm-identifier \(shellQuote(id)) --expiration-in-minutes 60"
        if let region { awsArgs += " --region \(shellQuote(region))" }
        if let profile { awsArgs += " --profile \(shellQuote(profile))" }
        return """
        command -v websocat >/dev/null || { echo "The MicroVM shell needs websocat: brew install websocat"; exit; }; \
        T=$(aws lambda-microvms create-microvm-shell-auth-token \(awsArgs) --query 'authToken."X-aws-proxy-auth"' --output text) && \
        stty raw -echo; websocat -b "wss://\(ep)/shell" -H "Sec-WebSocket-Protocol: lambda-microvms.authentication.$T, lambda-microvms, lambda-microvms.port.8022"; stty sane
        """
    }

    func openDesktop(_ id: String) async throws -> Any { throw SandboxError(message: "Lambda MicroVMs have no desktop.") }
    func desktopURL(_ id: String) async throws -> URL { throw SandboxError(message: "Lambda MicroVMs have no desktop.") }

    func status() async -> [String: Any]? {
        guard cliInstalled, let who = try? await cli(["sts", "get-caller-identity"], timeout: 20) else { return nil }
        return ["account": who["Account"] ?? "", "arn": who["Arn"] ?? ""]
    }

    // MARK: Agent calls

    private func endpoint(_ id: String) async throws -> String {
        if let e = lock.withLock({ endpoints[id] }) { return e }
        let r = try await cli(["lambda-microvms", "get-microvm", "--microvm-identifier", id], timeout: 30)
        guard let e = (r["endpoint"] as? String) ?? ((r["microvm"] as? [String: Any])?["endpoint"] as? String) else {
            throw SandboxError(message: "No endpoint for \(id)")
        }
        lock.withLock { endpoints[id] = e }
        return e
    }

    private func token(_ id: String, ports: [Int]) async throws -> String {
        let key = "\(id):\(ports)"
        if let t = lock.withLock({ tokens[key] }), t.expires > Date().addingTimeInterval(120) { return t.token }
        let allowed = "[" + ports.map { "{\"port\":\($0)}" }.joined(separator: ",") + "]"
        let r = try await cli(["lambda-microvms", "create-microvm-auth-token", "--microvm-identifier", id,
                               "--expiration-in-minutes", "60", "--allowed-ports", allowed], timeout: 30)
        guard let parts = r["authToken"] as? [String: Any], let t = parts["X-aws-proxy-auth"] as? String else {
            throw SandboxError(message: "No auth token for \(id)")
        }
        lock.withLock { tokens[key] = (t, Date().addingTimeInterval(55 * 60)) }
        return t
    }

    private func call(_ id: String, _ method: String, _ path: String, body: Data?, timeout: TimeInterval,
                      contentType: String = "application/json") async throws -> Any {
        let ep = try await endpoint(id)
        let token = try await token(id, ports: [Self.agentPort])
        guard let url = URL(string: "https://\(ep)\(path)") else { throw SandboxError(message: "bad endpoint \(ep)") }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.httpBody = body
        req.setValue(token, forHTTPHeaderField: "X-aws-proxy-auth")
        req.setValue("\(Self.agentPort)", forHTTPHeaderField: "X-aws-proxy-port")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) ?? String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(code) else {
            let msg = (obj as? [String: Any])?["error"] as? String ?? "\(obj)"
            throw SandboxError(message: "MicroVM agent \(code): \(msg)")
        }
        return obj
    }

    static func tarball(_ dir: String) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("studio-push-\(UUID().uuidString).tgz")
                let isGit = FileManager.default.fileExists(atPath: dir + "/.git")
                let script = isGit
                    ? "git ls-files -co --exclude-standard -z | tar --null -T - -czf \(shellQuote(file.path))"
                    : "tar --exclude .git --exclude node_modules -czf \(shellQuote(file.path)) ."
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = ["-c", script]
                p.currentDirectoryURL = URL(fileURLWithPath: dir)
                p.standardError = FileHandle.nullDevice
                let done = DispatchSemaphore(value: 0)
                p.terminationHandler = { _ in done.signal() }
                do { try p.run() } catch { cont.resume(throwing: error); return }
                done.wait()
                defer { try? FileManager.default.removeItem(at: file) }
                guard p.terminationStatus == 0, let data = try? Data(contentsOf: file) else {
                    cont.resume(throwing: SandboxError(message: "couldn't package \(dir)")); return
                }
                cont.resume(returning: data)
            }
        }
    }
}
