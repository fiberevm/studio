import Foundation

/// Anonymous usage telemetry (PostHog), on unless you turn it off in Settings → Telemetry or on the welcome
/// window's last page. It counts how Studio is used, never what you do with it: a random install id, the app
/// and macOS versions, and a few events (Studio opened, a session started and with which agent). No names,
/// paths, prompts, code, output, IP-based location or anything else that could identify you or your work.
enum Telemetry {
    static let pref = "telemetryEnabled"
    private static let token = "phc_q7FYZeELCWZVJo9u5m98p7dqdWnsSHru3i3ZqdSDxVzw"
    private static let endpoint = URL(string: "https://us.i.posthog.com/i/v0/e/")!
    private static let idKey = "telemetryId"

    static var enabled: Bool { UserDefaults.standard.object(forKey: pref) as? Bool ?? true }

    /// Only the real app sends: never a preview copy or a throwaway side-by-side instance.
    private static var sending: Bool {
        enabled && Bundle.main.bundleIdentifier == "dev.local.studio" && !CommandLine.arguments.contains("--no-restore")
    }

    /// A random id for this install, not derived from anything about you or this Mac.
    static var installId: String {
        if let id = UserDefaults.standard.string(forKey: idKey) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: idKey)
        return id
    }

    private static var base: [String: Any] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return [
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            "build": Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") == nil ? "source" : "release",
            "os_version": "\(os.majorVersion).\(os.minorVersion)",
            "arch": arch,
            "$lib": "studio",
            // anonymous: no person profile, no location from the IP address
            "$process_person_profile": false,
            "$geoip_disable": true,
            "$ip": "",
        ]
    }

    /// Send one event (off the main thread, fire and forget). `props` must never hold names, paths or content.
    static func capture(_ event: String, _ props: [String: Any] = [:]) {
        guard sending else { return }
        let body: [String: Any] = [
            "api_key": token, "event": event, "distinct_id": installId,
            "properties": base.merging(props) { _, new in new },
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req).resume()
    }
}
