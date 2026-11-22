import SwiftUI

/// The welcome window: shown once on first launch (and from Help → Welcome to Studio). A few pages, each
/// with a small animated illustration, ending with a check of what's installed and Open a Project….
enum Onboarding {
    static let windowId = "welcome"
    /// Bump to show it again to everyone after a big change.
    static let version = 1
    private static let key = "onboardingSeen"

    /// First launch of the real app (preview copies only with --onboarding).
    @MainActor static var shouldShow: Bool {
        let args = CommandLine.arguments
        if args.contains("--onboarding") { return true }
        if args.contains("--order-front") { return false }
        return UserDefaults.standard.integer(forKey: key) < version
    }
    static func markSeen() { UserDefaults.standard.set(version, forKey: key) }

    /// Asks the empty project window (if there is one) to run Open Folder….
    static let pickProject = Notification.Name("studio.onboarding.pickProject")
}

private let brand = SwiftUI.Color(red: 0.93, green: 0.54, blue: 0.36)        // #ee8a5c
private let brandDeep = SwiftUI.Color(red: 0.84, green: 0.37, blue: 0.20)    // #d65f33

struct OnboardingView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    // debug/screenshot aid: --onboarding-page N opens on that page
    @State private var page: Int = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--onboarding-page"), i + 1 < a.count, let n = Int(a[i + 1]) { return n }
        return 0
    }()
    @State private var forward = true
    private let count = 5

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                content(page)
                    .id(page)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            footer
        }
        .frame(width: 640, height: 520)
        .background(
            ZStack {
                SwiftUI.Color(nsColor: Theme.chrome)
                RadialGradient(colors: [brand.opacity(0.14), .clear], center: .init(x: 0.5, y: 0.28), startRadius: 0, endRadius: 360)
            }
            .ignoresSafeArea()
        )
        .preferredColorScheme(Theme.current.isLight ? .light : .dark)
        .onDisappear { Onboarding.markSeen() }
    }

    // MARK: Pages

    @ViewBuilder private func content(_ p: Int) -> some View {
        switch p {
        case 0:
            PageLayout(art: AnyView(WhyArt()), eyebrow: "Welcome to Studio", title: "Why we built Studio",
                       text: "We kept running a handful of coding agents at once: one in every terminal tab, each in a different repo, and always one quietly waiting on us. Studio is the workspace we wanted for that: all your agent sessions in one window, and it tells you which one needs you.")
        case 1:
            PageLayout(art: AnyView(SessionsArt()), eyebrow: "At a glance", title: "Every session, and what it's doing",
                       text: "The sidebar shows each session's status live: working, finished, or waiting for your answer. A red hand means it needs you, and you get a notification when it does.")
        case 2:
            PageLayout(art: AnyView(KeysArt()), eyebrow: "Keyboard first", title: "Move between agents without the mouse",
                       text: "⌘K jumps to any session or file in the project. ⇧⌘K sends a message to one, or to several at once, without leaving where you are. ⌘J takes you to whichever has waited longest.")
        case 3:
            PageLayout(art: AnyView(LayoutArt()), eyebrow: "Your workspace", title: "Splits, terminals and a browser",
                       text: "Put sessions side by side, open plain terminals (⌃`) and web tabs next to them. Sessions keep running when you quit Studio and come back exactly where they were.")
        default:
            ReadyPage()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule()
                        .fill(i == page ? brand : SwiftUI.Color.primary.opacity(0.18))
                        .frame(width: i == page ? 18 : 6, height: 6)
                        .onTapGesture { go(to: i) }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: page)
            Spacer()
            if page < count - 1 {
                Button("Skip") { close() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .padding(.trailing, 6)
            }
            if page > 0 {
                Button("Back") { go(to: page - 1) }
                    .buttonStyle(OnboardingButton(primary: false))
            }
            if page < count - 1 {
                Button("Continue") { go(to: page + 1) }
                    .buttonStyle(OnboardingButton(primary: true))
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Close") { close() }
                    .buttonStyle(OnboardingButton(primary: false))
                    .keyboardShortcut(.cancelAction)
                Button("Open a Project…") {
                    close()
                    NotificationCenter.default.post(name: Onboarding.pickProject, object: nil)
                }
                .buttonStyle(OnboardingButton(primary: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .background(SwiftUI.Color.primary.opacity(0.03))
        .overlay(alignment: .top) { SwiftUI.Color.primary.opacity(0.08).frame(height: 1) }
    }

    private func go(to p: Int) {
        guard p != page, (0..<count).contains(p) else { return }
        forward = p > page
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { page = p }
    }

    private func close() {
        Onboarding.markSeen()
        dismissWindow(id: Onboarding.windowId)
    }
}

private struct OnboardingButton: ButtonStyle {
    let primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: primary ? .semibold : .regular))
            .padding(.horizontal, 16).frame(height: 30)
            .foregroundStyle(primary ? SwiftUI.Color.white : SwiftUI.Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(primary ? AnyShapeStyle(LinearGradient(colors: [brand, brandDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                                  : AnyShapeStyle(SwiftUI.Color.primary.opacity(0.08)))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Rectangle())
    }
}

/// Illustration on top, then the words; the parts arrive one after another.
private struct PageLayout: View {
    let art: AnyView
    let eyebrow: String
    let title: String
    let text: String
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            art
                .frame(height: 210)
                .padding(.top, 34)
                .scaleEffect(shown ? 1 : 0.94)
                .opacity(shown ? 1 : 0)
            VStack(spacing: 10) {
                Text(eyebrow.uppercased())
                    .font(.system(size: 11, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(brand)
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text(text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 480)
            }
            .padding(.top, 26)
            .offset(y: shown ? 0 : 10)
            .opacity(shown ? 1 : 0)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .onAppear { withAnimation(.easeOut(duration: 0.5).delay(0.08)) { shown = true } }
    }
}

// MARK: - Illustrations

/// The app icon with a slow halo, and the three agents orbiting it.
private struct WhyArt: View {
    @State private var spin = false
    @State private var pop = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(AngularGradient(colors: [brand.opacity(0), brand.opacity(0.7), brand.opacity(0)], center: .center), lineWidth: 2)
                .frame(width: 176, height: 176)
                .rotationEffect(.degrees(spin ? 360 : 0))
            Circle().fill(brand.opacity(0.12)).frame(width: 150, height: 150).blur(radius: 18)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                .scaleEffect(pop ? 1 : 0.6)
            ForEach(Array(["Claude Code", "Codex", "Antigravity"].enumerated()), id: \.offset) { i, name in
                Chip(text: name)
                    .offset(x: 128 * cos(angle(i)), y: 96 * sin(angle(i)))
                    .opacity(pop ? 1 : 0)
                    .animation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.25 + Double(i) * 0.12), value: pop)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.62)) { pop = true }
            withAnimation(.linear(duration: 9).repeatForever(autoreverses: false)) { spin = true }
        }
    }
    private func angle(_ i: Int) -> CGFloat { [-2.5, -0.55, 1.45][i] }
}

private struct Chip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(SwiftUI.Color(nsColor: Theme.background)))
            .overlay(Capsule().stroke(SwiftUI.Color.primary.opacity(0.12)))
    }
}

/// A mini sidebar whose sessions change state every couple of seconds.
private struct SessionsArt: View {
    private let rows = ["Fix the login redirect", "Write tests for billing", "Refactor the API client", "Update the docs"]
    // a little story: each step is the status of every row
    private let steps: [[SessionStatus]] = [
        [.working, .working, .idle, .working],
        [.working, .waiting, .idle, .working],
        [.idle, .waiting, .working, .working],
        [.idle, .working, .working, .idle],
    ]
    @State private var step = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("MY-APP").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "plus").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).frame(height: 28)
            ForEach(rows.indices, id: \.self) { i in
                let s = steps[step][i]
                HStack(spacing: 8) {
                    StatusDot(status: s, attention: s == .idle).frame(width: 14)
                    Text(rows[i]).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text(label(s)).font(.system(size: 10.5))
                        .foregroundStyle(s == .waiting ? NeedsYouDot.red : SwiftUI.Color.secondary)
                        .contentTransition(.opacity)
                }
                .padding(.horizontal, 12).frame(height: 30)
                .background(s == .waiting ? NeedsYouDot.red.opacity(0.08) : .clear)
            }
        }
        .frame(width: 330)
        .padding(.bottom, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(SwiftUI.Color(nsColor: Theme.background)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(SwiftUI.Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .animation(.easeInOut(duration: 0.35), value: step)
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: true) { _ in
                Task { @MainActor in step = (step + 1) % steps.count }
            }
        }
        .onDisappear { timer?.invalidate() }
    }

    private func label(_ s: SessionStatus) -> String {
        switch s {
        case .working: return "Working"
        case .waiting: return "Needs you"
        default: return "Done"
        }
    }
}

/// Keycaps that press one after another, each with what it does.
private struct KeysArt: View {
    private let keys: [(String, String)] = [("⌘K", "Switch"), ("⇧⌘K", "Message"), ("⌘J", "Next up"), ("⌘N", "New session")]
    @State private var active = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 14) {
            ForEach(keys.indices, id: \.self) { i in
                let on = i == active
                VStack(spacing: 10) {
                    Text(keys[i].0)
                        .font(.system(size: 19, weight: .medium, design: .rounded))
                        .frame(width: 92, height: 64)
                        .background(
                            RoundedRectangle(cornerRadius: 11)
                                .fill(SwiftUI.Color(nsColor: Theme.background))
                                .shadow(color: .black.opacity(on ? 0.05 : 0.22), radius: on ? 1 : 0, y: on ? 1 : 4)
                        )
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(on ? brand : SwiftUI.Color.primary.opacity(0.12), lineWidth: on ? 2 : 1))
                        .offset(y: on ? 3 : 0)
                    Text(keys[i].1)
                        .font(.system(size: 12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? brand : SwiftUI.Color.secondary)
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: active)
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: true) { _ in
                Task { @MainActor in active = (active + 1) % keys.count }
            }
        }
        .onDisappear { timer?.invalidate() }
    }
}

/// A mini window that splits into a session, a terminal and a browser.
private struct LayoutArt: View {
    @State private var panes = 1
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(SwiftUI.Color.primary.opacity(0.2)).frame(width: 7, height: 7) }
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 22)
            HStack(spacing: 1) {
                pane("sparkles", "Claude Code", lines: 6, color: brand)
                if panes >= 2 {
                    VStack(spacing: 1) {
                        pane("terminal", "Terminal", lines: 3, color: .green)
                        if panes >= 3 { pane("globe", "localhost:3000", lines: 2, color: .blue).transition(.move(edge: .bottom).combined(with: .opacity)) }
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .background(SwiftUI.Color.primary.opacity(0.1))
        }
        .frame(width: 380, height: 200)
        .background(SwiftUI.Color(nsColor: Theme.chrome))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(SwiftUI.Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: panes)
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { _ in
                Task { @MainActor in panes = panes % 3 + 1 }
            }
        }
        .onDisappear { timer?.invalidate() }
    }

    private func pane(_ icon: String, _ title: String, lines: Int, color: SwiftUI.Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 9)).foregroundStyle(color)
                Text(title).font(.system(size: 9.5, weight: .medium)).lineLimit(1)
            }
            ForEach(0..<lines, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2).fill(SwiftUI.Color.primary.opacity(0.13))
                    .frame(width: CGFloat([110, 80, 130, 60, 100, 90][i % 6]), height: 5)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SwiftUI.Color(nsColor: Theme.background))
    }
}

// MARK: - Ready

/// What's installed, checked live, then Open a Project….
private struct ReadyPage: View {
    @ObservedObject private var checker = AgentChecker.shared
    @State private var shown = 0

    private struct Row { let ok: Bool?; let title: String; let detail: String }

    private var rows: [Row] {
        var out = Agent.allCases.map { a -> Row in
            let has = LaunchEnv.has(a.command)
            return Row(ok: has, title: a.name,
                       detail: has == nil ? "Checking…" : has! ? "Installed" : AgentChecker.installHint(a))
        }
        let tmux = SessionHost.tmux != nil
        out.append(Row(ok: tmux, title: "tmux",
                       detail: tmux ? "Sessions keep running when you quit Studio" : "brew install tmux — keeps sessions running when you quit Studio"))
        return out
    }

    var body: some View {
        let list = rows
        let anyAgent = Agent.allCases.contains { LaunchEnv.has($0.command) == true }
        VStack(spacing: 0) {
            Text("ALMOST THERE").font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(brand)
                .padding(.top, 44)
            Text(anyAgent || list.allSatisfy({ $0.ok == nil }) ? "You're set up" : "Install an agent to start")
                .font(.system(size: 24, weight: .semibold)).padding(.top, 10)
            Text("Studio runs the agent CLIs you already use. Here's what it found on this Mac.")
                .font(.system(size: 13.5)).foregroundStyle(.secondary).padding(.top, 8)
            VStack(spacing: 0) {
                ForEach(list.indices, id: \.self) { i in
                    let r = list[i]
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill((r.ok == true ? SwiftUI.Color.green : r.ok == false ? SwiftUI.Color.orange : SwiftUI.Color.gray).opacity(0.16))
                            Image(systemName: r.ok == true ? "checkmark" : r.ok == false ? "arrow.down" : "ellipsis")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(r.ok == true ? SwiftUI.Color.green : r.ok == false ? SwiftUI.Color.orange : SwiftUI.Color.gray)
                        }
                        .frame(width: 26, height: 26)
                        .scaleEffect(i < shown ? 1 : 0.3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title).font(.system(size: 13, weight: .medium))
                            Text(r.detail).font(.system(size: 11.5, design: r.ok == false ? .monospaced : .default))
                                .foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16).frame(height: 50)
                    .opacity(i < shown ? 1 : 0)
                    .offset(x: i < shown ? 0 : 16)
                    if i < list.count - 1 { SwiftUI.Color.primary.opacity(0.07).frame(height: 1).padding(.leading, 54) }
                }
            }
            .frame(width: 470)
            .background(RoundedRectangle(cornerRadius: 10).fill(SwiftUI.Color(nsColor: Theme.background)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(SwiftUI.Color.primary.opacity(0.1)))
            .padding(.top, 24)
            Text("Change your default agent and sign in under Settings → Agents.")
                .font(.system(size: 12)).foregroundStyle(.tertiary).padding(.top, 14)
            Spacer(minLength: 0)
        }
        .onAppear {
            LaunchEnv.refreshIfStale()
            for i in 0..<rows.count {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.7).delay(0.15 + Double(i) * 0.12)) { shown = i + 1 }
            }
        }
    }
}
