import SwiftUI
import WebKit
import UniformTypeIdentifiers

// MARK: - Markdown preview

/// A Markdown file rendered like on GitHub (the Preview button of a .md tab), in the theme's colors. Follows the
/// file as it changes. Relative images load from disk; links to other files open in Studio, web links in the browser.
/// The page can't run scripts of its own or reach the network beyond images (a README is untrusted content).
struct MarkdownPreview: NSViewRepresentable {
    @ObservedObject var doc: FileDoc
    var openFile: (String) -> Void
    @ObservedObject private var theme = ThemeChanges.shared

    static let scheme = "studio-file"
    private static let pageName = ".studio-markdown-preview.html"
    /// What the page may load from disk next to the Markdown file.
    private static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "bmp", "ico", "heic", "tiff"]

    final class Coordinator: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
        var html = ""
        var openFile: (String) -> Void = { _ in }
        var shown: (revision: Int, theme: String)?

        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            guard let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
            let path = url.path
            let data: Data?, mime: String
            if (path as NSString).lastPathComponent == MarkdownPreview.pageName {
                data = Data(html.utf8); mime = "text/html"
            } else if MarkdownPreview.imageTypes.contains((path as NSString).pathExtension.lowercased()) {
                data = FileManager.default.contents(atPath: path)
                mime = UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            } else { data = nil; mime = "" }
            guard let data else { task.didFailWithError(URLError(.fileDoesNotExist)); return }
            task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        }
        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, let url = action.request.url else { decisionHandler(.allow); return }
            if url.scheme == MarkdownPreview.scheme {
                // "#section" stays on the page; another file opens in Studio
                if (url.path as NSString).lastPathComponent == MarkdownPreview.pageName { decisionHandler(.allow); return }
                if FileManager.default.fileExists(atPath: url.path) { openFile(url.path) }
            } else if ["http", "https", "mailto"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator, forURLScheme: Self.scheme)
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")   // no white flash before the page paints
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        c.openFile = openFile
        let themeName = Theme.current.name
        if c.shown?.theme != themeName {
            // first show, or the theme changed: (re)load the page, which renders the current text
            c.html = Self.page(markdown: doc.text)
            c.shown = (doc.revision, themeName)
            var u = URLComponents()
            u.scheme = Self.scheme; u.host = "local"
            u.path = (doc.path as NSString).deletingLastPathComponent + "/" + Self.pageName
            if let url = u.url { web.load(URLRequest(url: url)) }
        } else if c.shown?.revision != doc.revision {
            c.shown?.revision = doc.revision
            web.evaluateJavaScript("render(\(Self.json(doc.text)))", completionHandler: nil)
        }
    }

    private static func json(_ s: String) -> String {
        let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
    }

    private static let marked: String = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Preview/marked.min.js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return js
    }()

    private static func hex(_ c: NSColor) -> String {
        guard let s = c.usingColorSpace(.sRGB) else { return "#888888" }
        return String(format: "#%02X%02X%02X", Int(round(s.redComponent * 255)), Int(round(s.greenComponent * 255)), Int(round(s.blueComponent * 255)))
    }

    private static func page(markdown: String) -> String {
        let nonce = UUID().uuidString
        let fg = hex(Theme.foreground), bg = hex(Theme.background), accent = hex(Theme.accent)
        let border = hex(Theme.border), chrome = hex(Theme.chrome)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src \(scheme): https: http: data:; media-src https:; style-src 'unsafe-inline'; script-src 'nonce-\(nonce)'">
        <style>
        html { background: \(bg); color: \(fg); }
        body { font: 14px/1.6 -apple-system, BlinkMacSystemFont, sans-serif; max-width: 860px; margin: 0 auto; padding: 28px 40px 60px; word-wrap: break-word; }
        h1, h2, h3, h4, h5, h6 { margin: 24px 0 12px; line-height: 1.25; font-weight: 600; }
        h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid \(border); }
        h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid \(border); }
        h3 { font-size: 1.25em; } h4 { font-size: 1em; } h5 { font-size: .875em; } h6 { font-size: .85em; opacity: .7; }
        body > :first-child { margin-top: 0; }
        p, ul, ol, pre, table, blockquote { margin: 0 0 16px; }
        a { color: \(accent); text-decoration: none; } a:hover { text-decoration: underline; }
        img { max-width: 100%; }
        code, kbd, pre { font: 12.5px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; }
        code { background: \(chrome); padding: .15em .4em; border-radius: 4px; }
        pre { background: \(chrome); border: 1px solid \(border); border-radius: 6px; padding: 12px 14px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        kbd { background: \(chrome); border: 1px solid \(border); border-bottom-width: 2px; border-radius: 4px; padding: .1em .4em; }
        blockquote { padding: 0 1em; border-left: .25em solid \(border); opacity: .8; }
        ul, ol { padding-left: 2em; } li + li { margin-top: .25em; } li > ul, li > ol { margin: .25em 0 0; }
        li:has(> input[type=checkbox]) { list-style: none; margin-left: -1.4em; }
        table { border-collapse: collapse; display: block; overflow-x: auto; }
        th, td { border: 1px solid \(border); padding: 6px 13px; } th { font-weight: 600; background: \(chrome); }
        hr { border: 0; border-top: 1px solid \(border); margin: 24px 0; }
        </style></head><body><div id="content"></div>
        <script nonce="\(nonce)">\(marked)</script>
        <script nonce="\(nonce)">
        function render(src) {
          var el = document.getElementById('content');
          if (typeof marked === 'undefined') { el.textContent = src; return; }
          el.innerHTML = marked.parse(src, { gfm: true });
          var seen = {};
          el.querySelectorAll('h1,h2,h3,h4,h5,h6').forEach(function (h) {   // GitHub-style ids, so #links work
            var id = h.textContent.trim().toLowerCase().replace(/[^\\p{L}\\p{N}\\s_-]/gu, '').replace(/\\s/g, '-');
            if (seen[id] !== undefined) { seen[id] += 1; id += '-' + seen[id]; } else { seen[id] = 0; }
            if (!h.id) h.id = id;
          });
        }
        render(\(json(markdown)));
        </script></body></html>
        """
    }
}

// MARK: - Image viewer

/// An image tab: the picture on a checkerboard (so transparency shows), fitted to the pane to start with.
/// Zoom with the − / + buttons or a pinch; double-click or click the percentage to switch between fit and 100%.
struct ImageViewer: View {
    let image: NSImage
    /// The image's size in pixels: what 100% shows it at.
    let pixels: CGSize
    @State private var zoom: CGFloat?        // nil: fit to the pane
    @State private var pinchStart: CGFloat?
    @ObservedObject private var theme = ThemeChanges.shared

    var body: some View {
        GeometryReader { geo in
            let fit = min(1, max(0.01, min((geo.size.width - 48) / max(pixels.width, 1), (geo.size.height - 48) / max(pixels.height, 1))))
            let scale = zoom ?? fit
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image).resizable().interpolation(scale >= 3 ? .none : .high)
                    .frame(width: pixels.width * scale, height: pixels.height * scale)
                    .background(Checkerboard())
                    .onTapGesture(count: 2) { zoom = zoom == nil ? 1 : nil }
                    .padding(24)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .gesture(MagnifyGesture()
                .onChanged { v in
                    let start = pinchStart ?? scale
                    if pinchStart == nil { pinchStart = start }
                    zoom = clamp(start * v.magnification)
                }
                .onEnded { _ in pinchStart = nil })
            .overlay(alignment: .bottomTrailing) { controls(scale: scale) }
        }
    }

    private func clamp(_ z: CGFloat) -> CGFloat { min(max(z, 0.05), 32) }

    private func controls(scale: CGFloat) -> some View {
        HStack(spacing: 0) {
            button("minus", help: "Zoom out") { zoom = clamp(scale / 1.25) }
            Button { zoom = zoom == nil ? 1 : nil } label: {
                Text("\(Int((scale * 100).rounded()))%").font(.system(size: 11)).monospacedDigit().frame(width: 46, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(zoom == nil ? "Fitted to the pane: click for 100%" : "Click to fit the pane")
            button("plus", help: "Zoom in") { zoom = clamp(scale * 1.25) }
        }
        .foregroundStyle(.secondary)
        .background(SwiftUI.Color(nsColor: Theme.chrome))
        .overlay(Rectangle().stroke(SwiftUI.Color(nsColor: Theme.border), lineWidth: 1))
        .padding(12)
    }

    private func button(_ icon: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold)).frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The grey squares image editors put behind transparent pixels.
private struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(SwiftUI.Color.primary.opacity(0.04)))
            var y: CGFloat = 0, row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : s
                while x < size.width {
                    ctx.fill(Path(CGRect(x: x, y: y, width: min(s, size.width - x), height: min(s, size.height - y))),
                             with: .color(SwiftUI.Color.primary.opacity(0.07)))
                    x += s * 2
                }
                y += s; row += 1
            }
        }
    }
}
