import AppKit

/// Editor token colors per theme, taken from the VS Code themes the app themes are named after
/// (a theme without an entry gets colors derived from its terminal palette).
struct SyntaxColors {
    let comment, string, number, keyword, storage, type, function, constant, property, tag, attribute, heading: NSColor
    let added, removed: NSColor

    private static func hex(_ s: String) -> NSColor {
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
    private init(_ c: [String]) {
        let h = c.map(Self.hex)
        (comment, string, number, keyword, storage, type) = (h[0], h[1], h[2], h[3], h[4], h[5])
        (function, constant, property, tag, attribute, heading) = (h[6], h[7], h[8], h[9], h[10], h[11])
        (added, removed) = (h[12], h[13])
    }
    private init(ansi a: [NSColor]) {
        (comment, string, number, keyword, storage, type) = (a[8], a[2], a[3], a[5], a[4], a[6])
        (function, constant, property, tag, attribute, heading) = (a[11], a[12], a[14], a[4], a[14], a[4])
        (added, removed) = (a[2], a[1])
    }

    //                 comment    string     number     keyword    storage    type       function   constant   property   tag        attribute  heading    added      removed
    private static let darkPlus = SyntaxColors(["6A9955", "CE9178", "B5CEA8", "C586C0", "569CD6", "4EC9B0", "DCDCAA", "4FC1FF", "9CDCFE", "569CD6", "9CDCFE", "569CD6", "81B88B", "F14C4C"])
    private static let palettes: [String: SyntaxColors] = [
        "clear-dark": SyntaxColors(["7F8C8D", "E5A07B", "B5CEA8", "D98BD0", "6CA8F0", "56C8B4", "E8D48A", "6CB8F0", "9CCFF5", "6CA8F0", "9CCFF5", "D97857", "7EC88B", "F06A5C"]),
        "dark-modern": darkPlus,
        "dark-plus": darkPlus,
        "light-plus": SyntaxColors(["008000", "A31515", "098658", "AF00DB", "0000FF", "267F99", "795E26", "0070C1", "001080", "800000", "E50000", "800000", "098658", "CD3131"]),
        "monokai": SyntaxColors(["88846F", "E6DB74", "AE81FF", "F92672", "66D9EF", "A6E22E", "A6E22E", "AE81FF", "FD971F", "F92672", "A6E22E", "E6DB74", "A6E22E", "F92672"]),
        "solarized-dark": SyntaxColors(["586E75", "2AA198", "D33682", "859900", "268BD2", "B58900", "268BD2", "CB4B16", "93A1A1", "268BD2", "93A1A1", "B58900", "859900", "DC322F"]),
        "one-dark-pro": SyntaxColors(["7F848E", "98C379", "D19A66", "C678DD", "C678DD", "E5C07B", "61AFEF", "D19A66", "E06C75", "E06C75", "D19A66", "E06C75", "98C379", "E06C75"]),
        "github-dark": SyntaxColors(["8B949E", "A5D6FF", "79C0FF", "FF7B72", "FF7B72", "FFA657", "D2A8FF", "79C0FF", "79C0FF", "7EE787", "79C0FF", "79C0FF", "7EE787", "FFA198"]),
        "dracula": SyntaxColors(["6272A4", "F1FA8C", "BD93F9", "FF79C6", "FF79C6", "8BE9FD", "50FA7B", "BD93F9", "8BE9FD", "FF79C6", "50FA7B", "BD93F9", "50FA7B", "FF5555"]),
    ]
    @MainActor static var current: SyntaxColors { palettes[Theme.current.id] ?? SyntaxColors(ansi: Theme.current.ansi) }
}

/// A language's lexical shape, enough for a one-pass tokenizer.
struct SyntaxLanguage {
    enum Kind { case code, markup, markdown, json, yaml, toml, css, diff, plain }
    var kind: Kind = .code
    var lineComments: [String] = []
    var blockComment: (String, String)? = nil
    var strings = Self.dq + "|" + Self.sq
    var keywords: Set<String> = []        // control flow
    var storage: Set<String> = []         // declarations and modifiers
    var constants: Set<String> = ["true", "false", "null", "nil"]
    var caseInsensitive = false
    var variables = false                  // $name / ${name} (shell, php, perl)
    var directives = false                 // #include, #if (C family)

    static let dq = #""(?:\\.|[^"\\\n])*""#
    static let sq = #"'(?:\\.|[^'\\\n])*'"#
    static let charLit = #"'(?:\\.|[^'\\\n])'"#
    static let backtick = #"`(?:\\.|[^`\\])*`"#
    static let tripleQ = #""""[\s\S]*?"""|'''[\s\S]*?'''"#

    private static func w(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

    static func forExtension(_ ext: String, name: String) -> SyntaxLanguage {
        let n = name.lowercased()
        if n == "dockerfile" || n.hasSuffix(".dockerfile") {
            return .init(lineComments: ["#"], keywords: w("FROM RUN CMD LABEL EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL AS"), caseInsensitive: true, variables: true)
        }
        if n == "makefile" || n == "gnumakefile" { return shell }
        switch ext {
        case "swift":
            return .init(lineComments: ["//"], blockComment: ("/*", "*/"), strings: tripleQ.components(separatedBy: "|")[0] + "|" + dq,
                         keywords: w("if else guard switch case default for in while repeat return break continue fallthrough throw throws rethrows try catch do defer where await async is as some any"),
                         storage: w("func let var class struct enum protocol extension import init deinit subscript typealias associatedtype static private fileprivate public internal open final override mutating nonmutating lazy weak unowned inout convenience required indirect actor nonisolated isolated operator precedencegroup get set willSet didSet self Self super"),
                         constants: w("true false nil"), directives: true)
        case "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts", "vue", "svelte":
            return .init(lineComments: ["//"], blockComment: ("/*", "*/"), strings: dq + "|" + sq + "|" + backtick,
                         keywords: w("if else switch case default for of in while do return break continue throw try catch finally await yield new delete typeof instanceof void import export from as with"),
                         storage: w("function const let var class extends implements interface type enum namespace module declare abstract public private protected readonly static async get set this super keyof infer satisfies"),
                         constants: w("true false null undefined NaN Infinity"), variables: false)
        case "py", "pyi", "pyw":
            return .init(lineComments: ["#"], strings: tripleQ + "|" + dq + "|" + sq,
                         keywords: w("if elif else for while in not and or is return break continue pass raise try except finally with as yield await import from assert del global nonlocal match case lambda"),
                         storage: w("def class async self cls"), constants: w("True False None"))
        case "go":
            return .init(lineComments: ["//"], blockComment: ("/*", "*/"), strings: dq + "|" + charLit + "|" + backtick,
                         keywords: w("if else switch case default for range return break continue goto fallthrough go defer select import package"),
                         storage: w("func var const type struct interface map chan"), constants: w("true false nil iota"))
        case "rs":
            return .init(lineComments: ["//"], blockComment: ("/*", "*/"), strings: dq + "|" + charLit,
                         keywords: w("if else match for in while loop return break continue use mod as where unsafe async await move ref crate super extern"),
                         storage: w("fn let mut const static struct enum trait impl type pub dyn self Self"), constants: w("true false None Some Ok Err"))
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "hxx", "m", "mm", "cu":
            return .init(lineComments: ["//"], blockComment: ("/*", "*/"), strings: dq + "|" + charLit,
                         keywords: w("if else switch case default for while do return break continue goto sizeof new delete throw try catch using namespace template typename operator"),
                         storage: w("int char float double long short unsigned signed void bool const static extern struct union enum typedef class public private protected virtual override inline auto constexpr volatile register mutable explicit friend this @interface @implementation @end @property self"),
                         constants: w("true false NULL nullptr nil YES NO"), directives: true)
        case "java", "kt", "kts", "scala", "cs", "dart", "groovy", "gradle":
            return .init(lineComments: ["//"], blockComment: ("/*", "*/"), strings: tripleQ.components(separatedBy: "|")[0] + "|" + dq + "|" + charLit,
                         keywords: w("if else switch case default for foreach in while do return break continue throw throws try catch finally new import package using namespace when is as await yield match"),
                         storage: w("class interface enum record object struct fun val var void int long short byte char float double boolean bool string public private protected internal static final abstract override sealed data open companion const readonly async extends implements this super"),
                         constants: w("true false null"))
        case "rb", "rake", "gemspec":
            return .init(lineComments: ["#"], keywords: w("if elsif else unless case when while until for in do end return break next redo retry yield begin rescue ensure raise then and or not require require_relative include extend"),
                         storage: w("def class module self attr_accessor attr_reader attr_writer private protected public lambda proc"), constants: w("true false nil"), variables: false)
        case "php":
            return .init(lineComments: ["//", "#"], blockComment: ("/*", "*/"),
                         keywords: w("if else elseif switch case default for foreach as while do return break continue throw try catch finally new echo require require_once include use namespace match yield"),
                         storage: w("function class interface trait enum extends implements public private protected static abstract final const fn var"), constants: w("true false null TRUE FALSE NULL"), variables: true)
        case "lua":
            return .init(lineComments: ["--"], blockComment: ("--[[", "]]"), keywords: w("if then else elseif end for in while do repeat until return break goto and or not"),
                         storage: w("function local self"), constants: w("true false nil"))
        case "sql":
            return .init(lineComments: ["--"], blockComment: ("/*", "*/"),
                         keywords: w("select from where and or not in is like between join inner left right outer full on group by order having limit offset union all distinct as case when then else end insert into values update set delete returning with exists"),
                         storage: w("create table view index alter drop add column primary key foreign references unique default constraint int integer bigint text varchar boolean timestamp date serial"),
                         constants: w("true false null"), caseInsensitive: true)
        case "sh", "bash", "zsh", "fish", "command", "envrc": return shell
        case "html", "htm", "xml", "svg", "plist", "xib", "storyboard", "xhtml", "entitlements": return .init(kind: .markup)
        case "md", "markdown", "mdx": return .init(kind: .markdown)
        case "json", "jsonc", "json5", "jsonl", "geojson", "webmanifest", "resolved", "babelrc", "eslintrc", "prettierrc": return .init(kind: .json)
        case "yml", "yaml": return .init(kind: .yaml)
        case "toml", "ini", "cfg", "conf", "env", "properties", "editorconfig", "gitconfig": return .init(kind: .toml)
        case "css", "scss", "sass", "less": return .init(kind: .css)
        case "diff", "patch": return .init(kind: .diff)
        case "txt", "log", "csv", "tsv", "text": return .init(kind: .plain)
        case "": return n.hasPrefix(".") ? .init(kind: .toml) : shell
        default:
            return .init(lineComments: ["//", "#"], blockComment: ("/*", "*/"))
        }
    }

    static let shell = SyntaxLanguage(lineComments: ["#"],
        keywords: w("if then else elif fi case esac for in while until do done return break continue function select time exit export local readonly declare unset source alias set shift trap eval exec"),
        constants: w("true false"), variables: true)
}

/// One-pass, regex-driven highlighting: a single alternation is matched left to right, so a `//` inside a string
/// stays a string and a quote inside a comment stays a comment. Words are then sorted into keyword, declaration,
/// constant, type (Capitalized), function (followed by `(`) and member (after `.`).
@MainActor
enum Highlighter {
    private static var cache: [String: NSRegularExpression] = [:]

    private static func regex(_ key: String, _ build: () -> String) -> NSRegularExpression {
        if let r = cache[key] { return r }
        let r = try! NSRegularExpression(pattern: build(), options: [.anchorsMatchLines])
        cache[key] = r
        return r
    }

    private static func esc(_ s: String) -> String { NSRegularExpression.escapedPattern(for: s) }

    /// Groups: 1 comment, 2 string, 3 number, 4 attribute/directive, 5 variable, 6 word.
    private static func codePattern(_ l: SyntaxLanguage) -> String {
        var comment: [String] = []
        if let (a, b) = l.blockComment { comment.append(esc(a) + "[\\s\\S]*?(?:" + esc(b) + "|\\z)") }
        for c in l.lineComments { comment.append(c == "#" ? "(?<![\\w$])#(?![{\\[]).*$" : esc(c) + ".*$") }
        let commentP = comment.isEmpty ? "(?!x)x" : comment.joined(separator: "|")
        let number = #"(?<![\w$])(?:0[xX][0-9a-fA-F_]+|0[bBoO][0-7_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)[a-zA-Z]{0,3}\b"#
        let attr = l.directives ? #"^[ \t]*#[ \t]*\w+|@[A-Za-z_]\w*"# : #"@[A-Za-z_]\w*"#
        let variable = l.variables ? #"\$\{[^}\n]*\}|\$[A-Za-z_]\w*|\$[0-9@#?*!$-]"# : "(?!x)x"
        return "(\(commentP))|(\(l.strings))|(\(number))|(\(attr))|(\(variable))|([A-Za-z_][A-Za-z0-9_]*)"
    }

    static func apply(to tv: NSTextView, ext: String, name: String) {
        guard let storage = tv.textStorage else { return }
        let len = storage.length
        guard len > 0, len < 2_000_000 else { return }
        let s = storage.string as NSString
        let all = NSRange(location: 0, length: len)
        let c = SyntaxColors.current
        let lang = SyntaxLanguage.forExtension(ext, name: name)
        let base = tv.font ?? Theme.font(12)
        let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        storage.beginEditing()
        defer { storage.endEditing() }
        var baseAttrs: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: Theme.foreground]
        if let p = tv.defaultParagraphStyle { baseAttrs[.paragraphStyle] = p }
        if let shift = (tv as? CodeTextView)?.baselineShift, shift != 0 { baseAttrs[.baselineOffset] = shift }
        storage.setAttributes(baseAttrs, range: all)
        func color(_ r: NSRange, _ col: NSColor) { storage.addAttribute(.foregroundColor, value: col, range: r) }

        switch lang.kind {
        case .plain:
            return
        case .code:
            let re = regex("code." + ext + "." + name) { codePattern(lang) }
            var prevWord = ""
            re.enumerateMatches(in: s as String, range: all) { m, _, _ in
                guard let m else { return }
                let r = m.range
                if m.range(at: 1).location != NSNotFound { color(r, c.comment); return }
                if m.range(at: 2).location != NSNotFound { color(r, c.string); return }
                if m.range(at: 3).location != NSNotFound { color(r, c.number); return }
                if m.range(at: 4).location != NSNotFound { color(r, c.keyword); return }
                if m.range(at: 5).location != NSNotFound { color(r, c.property); return }
                let word = s.substring(with: r)
                let key = lang.caseInsensitive ? word.lowercased() : word
                defer { prevWord = key }
                if lang.keywords.contains(key) || (lang.caseInsensitive && lang.keywords.contains(word.uppercased())) {
                    color(r, c.keyword); return
                }
                if lang.storage.contains(key) { color(r, c.storage); return }
                if lang.constants.contains(key) { color(r, c.constant); return }
                let before = r.location > 0 ? s.character(at: r.location - 1) : 0
                var after = r.location + r.length
                while after < len, s.character(at: after) == 32 { after += 1 }
                let next = after < len ? s.character(at: after) : 0
                if ["func", "def", "fn", "function", "fun"].contains(prevWord) || next == 40 /* ( */ {
                    color(r, c.function); return
                }
                if let f = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(f) {
                    let allCaps = word.count > 1 && word == word.uppercased()
                    color(r, allCaps ? c.constant : c.type); return
                }
                if before == 46 /* . */ { color(r, c.property) }
            }
        case .markup:
            let re = regex("markup") {
                #"(<!--[\s\S]*?(?:-->|\z))|(<!\[CDATA\[[\s\S]*?\]\]>)|(</?)([A-Za-z][\w:.-]*)|([A-Za-z_:][\w:.-]*)(?=\s*=\s*["'])|("[^"]*"|'[^']*')|(&#?\w+;)|(<\?[\s\S]*?\?>|<![^>]*>)"#
            }
            re.enumerateMatches(in: s as String, range: all) { m, _, _ in
                guard let m else { return }
                if m.range(at: 1).location != NSNotFound { color(m.range, c.comment) }
                else if m.range(at: 2).location != NSNotFound { color(m.range, c.string) }
                else if m.range(at: 4).location != NSNotFound { color(m.range(at: 4), c.tag) }
                else if m.range(at: 5).location != NSNotFound { color(m.range, c.attribute) }
                else if m.range(at: 6).location != NSNotFound { color(m.range, c.string) }
                else if m.range(at: 7).location != NSNotFound { color(m.range, c.constant) }
                else if m.range(at: 8).location != NSNotFound { color(m.range, c.comment) }
            }
        case .markdown:
            let re = regex("markdown") {
                #"(^```[\s\S]*?(?:^```|\z)|^~~~[\s\S]*?(?:^~~~|\z))|(^#{1,6}[ \t].*$)|(`[^`\n]+`)|(\*\*[^*\n]+\*\*|__[^_\n]+__)|((?<![*\w])\*[^*\s][^*\n]*\*(?!\*)|(?<![_\w])_[^_\s][^_\n]*_(?!\w))|(!?\[[^\]\n]*\]\([^)\n]*\)|<https?://[^>\s]+>)|(^[ \t]*(?:[-*+]|\d+[.)])[ \t]|^>.*$)|(<!--[\s\S]*?-->)|(^(?:---+|\*\*\*+)[ \t]*$)"#
            }
            re.enumerateMatches(in: s as String, range: all) { m, _, _ in
                guard let m else { return }
                let r = m.range
                if m.range(at: 1).location != NSNotFound { color(r, c.string) }
                else if m.range(at: 2).location != NSNotFound { color(r, c.heading); storage.addAttribute(.font, value: bold, range: r) }
                else if m.range(at: 3).location != NSNotFound { color(r, c.string) }
                else if m.range(at: 4).location != NSNotFound { storage.addAttribute(.font, value: bold, range: r); color(r, c.storage) }
                else if m.range(at: 5).location != NSNotFound { color(r, c.keyword) }
                else if m.range(at: 6).location != NSNotFound { color(r, c.function) }
                else if m.range(at: 7).location != NSNotFound { color(r, s.character(at: r.location) == 62 ? c.comment : c.keyword) }
                else { color(r, c.comment) }
            }
        case .json:
            let re = regex("json") {
                #"(//.*$|/\*[\s\S]*?\*/)|("(?:\\.|[^"\\\n])*")(?=\s*:)|("(?:\\.|[^"\\\n])*")|(-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)|\b(true|false|null)\b"#
            }
            re.enumerateMatches(in: s as String, range: all) { m, _, _ in
                guard let m else { return }
                let col = [c.comment, c.property, c.string, c.number, c.constant]
                for g in 1...5 where m.range(at: g).location != NSNotFound { color(m.range, col[g - 1]); return }
            }
        case .yaml:
            let re = regex("yaml") {
                #"((?<!\S)#.*$)|(^[ \t]*(?:-[ \t]+)?)([^\s#:"'{}\[\],&*!|>][^#:\n]*?|"[^"\n]*"|'[^'\n]*')(?=:(?:[ \t]|$))|("(?:\\.|[^"\\\n])*"|'[^'\n]*')|([&*][\w-]+|![\w!/-]*)|((?<![\w.])-?\d+(?:\.\d+)?(?![\w.]))|\b(true|false|null|yes|no|on|off|True|False|Null|~)\b|(^---$|^\.\.\.$|[|>][-+]?$)"#
            }
            re.enumerateMatches(in: s as String, range: all) { m, _, _ in
                guard let m else { return }
                if m.range(at: 1).location != NSNotFound { color(m.range, c.comment) }
                else if m.range(at: 3).location != NSNotFound { color(m.range(at: 3), c.property) }
                else if m.range(at: 4).location != NSNotFound { color(m.range, c.string) }
                else if m.range(at: 5).location != NSNotFound { color(m.range, c.type) }
                else if m.range(at: 6).location != NSNotFound { color(m.range, c.number) }
                else if m.range(at: 7).location != NSNotFound { color(m.range, c.constant) }
                else if m.range(at: 8).location != NSNotFound { color(m.range, c.keyword) }
            }
        case .toml:
            let re = regex("toml") {
                #"((?<!\S)[#;].*$)|(^[ \t]*\[\[?[^\]\n]*\]\]?)|(^[ \t]*(?:export[ \t]+)?[\w.\-"']+)(?=[ \t]*[=:])|("""[\s\S]*?"""|"(?:\\.|[^"\\\n])*"|'[^'\n]*')|((?<![\w.])-?\d[\d_]*(?:\.\d+)?(?![\w.]))|\b(true|false)\b|(\$\{[^}\n]*\}|\$\w+)"#
            }
            re.enumerateMatches(in: s as String, range: all) { m, _, _ in
                guard let m else { return }
                let col = [c.comment, c.type, c.property, c.string, c.number, c.constant, c.property]
                for g in 1...7 where m.range(at: g).location != NSNotFound { color(m.range, col[g - 1]); return }
            }
        case .css:
            let re = regex("css") {
                #"(/\*[\s\S]*?(?:\*/|\z)|(?<![:\w])//.*$)|("(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')|(#[0-9a-fA-F]{3,8}\b(?=[^{]*[;}\n]))|(@[\w-]+|!important)|(^[ \t]+[\w-]+)(?=[ \t]*:)|((?<![\w-])-?\d*\.?\d+(?:px|em|rem|%|vh|vw|s|ms|deg|fr|ch|pt)?\b)|([.#][A-Za-z_-][\w-]*|::?[\w-]+)|(\$[\w-]+|--[\w-]+|var\b)|([\w-]+)(?=\()"#
            }
            re.enumerateMatches(in: s as String, range: all) { m, _, _ in
                guard let m else { return }
                let col = [c.comment, c.string, c.number, c.keyword, c.property, c.number, c.type, c.constant, c.function]
                for g in 1...9 where m.range(at: g).location != NSNotFound { color(m.range, col[g - 1]); return }
            }
        case .diff:
            let re = regex("diff") { #"(^\+(?!\+\+ ).*$)|(^-(?!-- ).*$)|(^@@.*$)|(^(?:diff |index |\+\+\+ |--- |new file|deleted file).*$)"# }
            re.enumerateMatches(in: s as String, range: all) { m, _, _ in
                guard let m else { return }
                let col = [c.added, c.removed, c.function, c.keyword]
                for g in 1...4 where m.range(at: g).location != NSNotFound { color(m.range, col[g - 1]); return }
            }
        }
    }
}
