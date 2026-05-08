// vscode-textmate `theme.ts`

import Foundation

public typealias ScopeName = String

// MARK: - Font style

public struct FontStyle: Equatable, Hashable, Sendable, RawRepresentable {
    public typealias RawValue = Int32
    public let rawValue: Int32

    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let notSet = FontStyle(rawValue: -1)
    public static let none = FontStyle(rawValue: 0)
    public static let italic = FontStyle(rawValue: 1)
    public static let bold = FontStyle(rawValue: 2)
    public static let underline = FontStyle(rawValue: 4)
    public static let strikethrough = FontStyle(rawValue: 8)

    public static func | (lhs: FontStyle, rhs: FontStyle) -> FontStyle {
        if lhs == .notSet { return rhs }
        if rhs == .notSet { return lhs }
        return FontStyle(rawValue: lhs.rawValue | rhs.rawValue)
    }

    public func contains(_ style: FontStyle) -> Bool {
        if self == .notSet || style == .notSet { return false }
        return (rawValue & style.rawValue) == style.rawValue
    }

    public init(string: String?) {
        guard let string, !string.isEmpty else {
            self = .notSet
            return
        }
        var r = FontStyle.none
        for seg in string.split(separator: " ") {
            switch seg {
            case "italic": r = r | .italic
            case "bold": r = r | .bold
            case "underline": r = r | .underline
            case "strikethrough": r = r | .strikethrough
            default: break
            }
        }
        self = r
    }
}

public func fontStyleDescription(_ fs: FontStyle) -> String {
    if fs == .notSet { return "not set" }
    var s = ""
    if fs.contains(.italic) { s += "italic " }
    if fs.contains(.bold) { s += "bold " }
    if fs.contains(.underline) { s += "underline " }
    if fs.contains(.strikethrough) { s += "strikethrough " }
    return s.isEmpty ? "none" : s.trimmingCharacters(in: .whitespaces)
}

// MARK: - Raw theme

public protocol IRawTheme: Sendable {
    var name: String? { get }
    var settings: [IRawThemeSetting] { get }
}

public protocol IRawThemeSetting: Sendable {
    var name: String? { get }
    var scope: ThemeScopeField? { get }
    var themeSettings: TMRawThemeStyleValues { get }
}

public enum ThemeScopeField: Sendable {
    case string(String)
    case array([String])
}

public protocol TMRawThemeStyleValues: Sendable {
    var fontStyle: String? { get }
    var foregroundHex: String? { get }
    var backgroundHex: String? { get }
    var fontFamily: String? { get }
    var fontSize: Double? { get }
    var lineHeight: Double? { get }
}

// MARK: - Style + scope stack

public struct StyleAttributes: Sendable {
    public let fontStyle: FontStyle
    public let foregroundId: Int
    public let backgroundId: Int
    public let fontFamily: String
    public let fontSize: Double
    public let lineHeight: Double

    public init(fontStyle: FontStyle, foregroundId: Int, backgroundId: Int, fontFamily: String, fontSize: Double, lineHeight: Double) {
        self.fontStyle = fontStyle
        self.foregroundId = foregroundId
        self.backgroundId = backgroundId
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineHeight = lineHeight
    }
}

public final class ScopeStack {
    public let parent: ScopeStack?
    public let scopeName: ScopeName

    public init(_ parent: ScopeStack?, _ scopeName: ScopeName) {
        self.parent = parent
        self.scopeName = scopeName
    }

    public static func push(_ path: ScopeStack?, _ scopeNames: [ScopeName]) -> ScopeStack? {
        var p = path
        for n in scopeNames {
            p = ScopeStack(p, n)
        }
        return p
    }

    public static func from(_ segments: ScopeName...) -> ScopeStack? { from(Array(segments)) }

    public static func from(_ segments: [ScopeName]) -> ScopeStack? {
        var r: ScopeStack?
        for s in segments { r = ScopeStack(r, s) }
        return r
    }

    public func push(_ scopeName: ScopeName) -> ScopeStack { ScopeStack(self, scopeName) }

    public func getSegments() -> [ScopeName] {
        var item: ScopeStack? = self
        var out: [ScopeName] = []
        while let i = item {
            out.append(i.scopeName)
            item = i.parent
        }
        out.reverse()
        return out
    }

    public func extends(_ other: ScopeStack) -> Bool {
        if self === other { return true }
        guard let parent else { return false }
        return parent.extends(other)
    }

    public func getExtensionIfDefined(base: ScopeStack?) -> [ScopeName]? {
        var result: [ScopeName] = []
        var item: ScopeStack? = self
        while let i = item, i !== base {
            result.append(i.scopeName)
            item = i.parent
        }
        return item === base ? result.reversed() : nil
    }
}

extension ScopeStack: CustomStringConvertible {
    public var description: String { getSegments().joined(separator: " ") }
}

// MARK: - Parsed rules

public struct ParsedThemeRule: Sendable {
    public let scope: ScopeName
    public let parentScopes: [ScopeName]?
    public let index: Int
    public let fontStyle: FontStyle
    public let foreground: String?
    public let background: String?
    public let fontFamily: String
    public let fontSize: Double
    public let lineHeight: Double

    init(scope: ScopeName, parentScopes: [ScopeName]?, index: Int, fontStyle: FontStyle,
         foreground: String?, background: String?, fontFamily: String, fontSize: Double, lineHeight: Double) {
        self.scope = scope
        self.parentScopes = parentScopes
        self.index = index
        self.fontStyle = fontStyle
        self.foreground = foreground
        self.background = background
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineHeight = lineHeight
    }
}

private let emptyFrozenParentScopes: [ScopeName] = []

final class ThemeTrieElementRuleBox {
    var scopeDepth: Int
    let parentScopes: [ScopeName]
    var fontStyleValue: FontStyle
    var foreground: Int
    var background: Int
    var fontFamily: String
    var fontSize: Double
    var lineHeight: Double

    init(scopeDepth: Int, parentScopes: [ScopeName]?, fontStyle: FontStyle,
         foreground: Int, background: Int, fontFamily: String, fontSize: Double, lineHeight: Double) {
        self.scopeDepth = scopeDepth
        self.parentScopes = parentScopes ?? emptyFrozenParentScopes
        self.fontStyleValue = fontStyle
        self.foreground = foreground
        self.background = background
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineHeight = lineHeight
    }

    /// Copy for trie descent (renamed from `clone` to avoid Swift 6 key-path / method-name diagnostics).
    func duplicatedRuleBox() -> ThemeTrieElementRuleBox {
        ThemeTrieElementRuleBox(scopeDepth: scopeDepth, parentScopes: parentScopes,
                                fontStyle: fontStyleValue, foreground: foreground, background: background,
                                fontFamily: fontFamily, fontSize: fontSize, lineHeight: lineHeight)
    }

    func acceptOverwrite(scopeDepth: Int, fontStyle: FontStyle, foreground: Int, background: Int,
                         fontFamily: String, fontSize: Double, lineHeight: Double) {
        if self.scopeDepth > scopeDepth {} // parity with TS noop log
        self.scopeDepth = scopeDepth

        if fontStyle != FontStyle.notSet {
            fontStyleValue = fontStyle
        }
        if foreground != 0 { self.foreground = foreground }
        if background != 0 { self.background = background }
        if !fontFamily.isEmpty { self.fontFamily = fontFamily }
        if fontSize != 0 { self.fontSize = fontSize }
        if lineHeight != 0 { self.lineHeight = lineHeight }
    }
}

extension ThemeTrieElementRuleBox {
    static func cloneRules(_ rows: [ThemeTrieElementRuleBox]) -> [ThemeTrieElementRuleBox] {
        rows.map { $0.duplicatedRuleBox() }
    }

    static func cmpSpecificity(lhs: ThemeTrieElementRuleBox, rhs: ThemeTrieElementRuleBox) -> Int {
        if lhs.scopeDepth != rhs.scopeDepth {
            return rhs.scopeDepth &- lhs.scopeDepth
        }

        var aParentIndex = 0
        var bParentIndex = 0

        while true {
            if aParentIndex < lhs.parentScopes.count, lhs.parentScopes[aParentIndex] == ">" {
                aParentIndex += 1
                continue
            }
            if bParentIndex < rhs.parentScopes.count, rhs.parentScopes[bParentIndex] == ">" {
                bParentIndex += 1
                continue
            }

            if aParentIndex >= lhs.parentScopes.count || bParentIndex >= rhs.parentScopes.count {
                break
            }

            let parentScopeLengthDiff = rhs.parentScopes[bParentIndex].count &- lhs.parentScopes[aParentIndex].count

            if parentScopeLengthDiff != 0 {
                return parentScopeLengthDiff
            }

            aParentIndex += 1
            bParentIndex += 1
        }

        return rhs.parentScopes.count &- lhs.parentScopes.count
    }
}

final class ThemeTrieElement {
    private(set) var mainRule: ThemeTrieElementRuleBox
    private var rulesWithParentScopes: [ThemeTrieElementRuleBox]
    private var children: [String: ThemeTrieElement]

    init(_ mainRule: ThemeTrieElementRuleBox, rulesWithParentScopes: [ThemeTrieElementRuleBox], children: [String: ThemeTrieElement]) {
        self.mainRule = mainRule
        self.rulesWithParentScopes = rulesWithParentScopes
        self.children = children
    }

    func match(_ remainder: ScopeName) -> [ThemeTrieElementRuleBox] {
        if remainder != "" {
            if let dot = remainder.firstIndex(of: ".") {
                let head = String(remainder[..<dot])
                let tail = String(remainder[remainder.index(after: dot)...])
                if let next = children[head] {
                    return next.match(tail)
                }
            } else {
                if let leaf = children[remainder] {
                    return leaf.match("")
                }
            }
        }

        var rules = rulesWithParentScopes + [mainRule]
        rules.sort { ThemeTrieElementRuleBox.cmpSpecificity(lhs: $0, rhs: $1) < 0 }
        return rules
    }

    func insert(scopeDepth: Int, scopeRemainder: ScopeName, parentScopes: [ScopeName]?,
                fontStyle: FontStyle, foreground: Int, background: Int,
                fontFamily: String, fontSize: Double, lineHeight: Double) {
        guard scopeRemainder != "" else {
            _insertHere(scopeDepth: scopeDepth, parentScopes: parentScopes, fontStyle: fontStyle,
                        foreground: foreground, background: background, fontFamily: fontFamily,
                        fontSize: fontSize, lineHeight: lineHeight)
            return
        }

        guard let dot = scopeRemainder.firstIndex(of: ".") else {
            let head = scopeRemainder
            let tail = ""
            descend(head: head, tail: tail, scopeDepth: scopeDepth, parentScopes: parentScopes,
                    fontStyle: fontStyle, foreground: foreground, background: background,
                    fontFamily: fontFamily, fontSize: fontSize, lineHeight: lineHeight)
            return
        }

        let head = String(scopeRemainder[..<dot])
        let tail = String(scopeRemainder[scopeRemainder.index(after: dot)...])
        descend(head: head, tail: tail, scopeDepth: scopeDepth, parentScopes: parentScopes,
                fontStyle: fontStyle, foreground: foreground, background: background,
                fontFamily: fontFamily, fontSize: fontSize, lineHeight: lineHeight)
    }

    private func descend(head: ScopeName, tail: ScopeName, scopeDepth: Int, parentScopes: [ScopeName]?,
                         fontStyle: FontStyle, foreground: Int, background: Int,
                         fontFamily: String, fontSize: Double, lineHeight: Double) {
        if let existing = children[head] {
            existing.insert(scopeDepth: scopeDepth + 1, scopeRemainder: tail, parentScopes: parentScopes,
                             fontStyle: fontStyle, foreground: foreground, background: background,
                             fontFamily: fontFamily, fontSize: fontSize, lineHeight: lineHeight)
        } else {
            let neo = ThemeTrieElement(mainRule.duplicatedRuleBox(), rulesWithParentScopes: ThemeTrieElementRuleBox.cloneRules(rulesWithParentScopes),
                                       children: [:])
            neo.insert(scopeDepth: scopeDepth + 1, scopeRemainder: tail, parentScopes: parentScopes,
                       fontStyle: fontStyle, foreground: foreground, background: background,
                       fontFamily: fontFamily, fontSize: fontSize, lineHeight: lineHeight)
            children[head] = neo
        }
    }

    private func _insertHere(scopeDepth: Int, parentScopes: [ScopeName]?, fontStyle: FontStyle,
                             foreground: Int, background: Int, fontFamily: String, fontSize: Double, lineHeight: Double) {
        guard let ps = parentScopes else {
            mainRule.acceptOverwrite(scopeDepth: scopeDepth, fontStyle: fontStyle, foreground: foreground, background: background,
                                     fontFamily: fontFamily, fontSize: fontSize, lineHeight: lineHeight)
            return
        }

        if let ix = rulesWithParentScopes.firstIndex(where: { tmStrArrCmp($0.parentScopes, ps) == 0 }) {
            rulesWithParentScopes[ix].acceptOverwrite(scopeDepth: scopeDepth, fontStyle: fontStyle, foreground: foreground,
                                                      background: background, fontFamily: fontFamily, fontSize: fontSize, lineHeight: lineHeight)
            return
        }

        var nextFontStyle = fontStyle == .notSet ? mainRule.fontStyleValue : fontStyle
        var nextFg = foreground == 0 ? mainRule.foreground : foreground
        var nextBg = background == 0 ? mainRule.background : background
        var nextFF = fontFamily.isEmpty ? mainRule.fontFamily : fontFamily
        var nextFS = fontSize == 0 ? mainRule.fontSize : fontSize
        var nextLH = lineHeight == 0 ? mainRule.lineHeight : lineHeight

        rulesWithParentScopes.append(
            ThemeTrieElementRuleBox(scopeDepth: scopeDepth, parentScopes: ps, fontStyle: nextFontStyle,
                                    foreground: nextFg, background: nextBg, fontFamily: nextFF,
                                    fontSize: nextFS, lineHeight: nextLH)
        )
    }
}

final class TMColorMap {
    private let frozen: Bool
    private var lastColorId: Int
    private var id2color: [String] = []
    private var color2id: [String: Int] = [:]

    init(_ preset: [String]?) {
        if let preset, !preset.isEmpty {
            frozen = true
            self.lastColorId = preset.count
            id2color = preset.map { $0.uppercased() }
            for (i, value) in id2color.enumerated() {
                color2id[value] = i
            }
        } else {
            frozen = false
            lastColorId = 0
        }
    }

    func getId(_ color: String?) -> Int {
        guard let raw = color, !raw.isEmpty else { return 0 }
        let up = raw.uppercased()
        if let existing = color2id[up] { return existing }
        if frozen {
            fatalError("Missing color in color map - \(up)")
        }

        lastColorId += 1
        let nextId = lastColorId
        color2id[up] = nextId
        while id2color.count < nextId + 1 {
            id2color.append("")
        }
        id2color[nextId] = up
        return nextId
    }

    func palette() -> [String] {
        var copy = id2color
        if copy.isEmpty { return copy }
        if let last = copy.lastIndex(where: { !$0.isEmpty }) {
            return Array(copy[..<last.advanced(by: 1)])
        }
        return copy
    }
}

private func _matchesScope(_ scopeName: ScopeName, _ scopePattern: ScopeName) -> Bool {
    guard !scopeName.isEmpty else { return false }
    if scopePattern == scopeName { return true }
    let len = scopePattern.count
    guard scopeName.count > len else { return false }
    let idx = scopeName.index(scopeName.startIndex, offsetBy: len)
    guard String(scopeName[..<idx]) == scopePattern else { return false }
    return scopeName[idx] == "."
}

private func _scopePathMatchesParentScopes(_ scopePath: ScopeStack?, _ parentScopes: [ScopeName]) -> Bool {
    if parentScopes.isEmpty { return true }
    var walker: ScopeStack? = scopePath
    var index = parentScopes.startIndex
    while index < parentScopes.endIndex {
        var pattern = parentScopes[index]
        var mustMatch = false
        if pattern == ">" {
            if index == parentScopes.index(before: parentScopes.endIndex) { return false }
            index = parentScopes.index(after: index)
            pattern = parentScopes[index]
            mustMatch = true
        }

        while let cur = walker {
            if _matchesScope(cur.scopeName, pattern) {
                break
            }
            if mustMatch { return false }
            walker = cur.parent
        }

        guard walker != nil else { return false }
        walker = walker!.parent
        index = parentScopes.index(after: index)
    }
    return true
}

public func parseTheme(source: IRawTheme?) -> [ParsedThemeRule] {
    guard let source, !source.settings.isEmpty else { return [] }

    var result: [ParsedThemeRule] = []
    result.reserveCapacity(source.settings.count)

    for (idx, entry) in source.settings.enumerated() {
        let scopeFields: [ScopeName] = {
            switch entry.scope {
            case nil, .some(.string("")):
                return [""]
            case .some(.string(let s)):
                let stripped = stripCommas(s)
                return stripped.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            case .some(.array(let arr)):
                return arr
            }
        }()

        let fontStyle = FontStyle(string: entry.themeSettings.fontStyle)
        let foreground: String? = {
            guard let f = entry.themeSettings.foregroundHex, isValidHexColor(f) else { return nil }
            return f
        }()
        let background: String? = {
            guard let b = entry.themeSettings.backgroundHex, isValidHexColor(b) else { return nil }
            return b
        }()

        let fontFamily = entry.themeSettings.fontFamily ?? ""
        let fontSize = entry.themeSettings.fontSize ?? 0
        let lineHeight = entry.themeSettings.lineHeight ?? 0

        for scoped in scopeFields {
            let trimmed = scoped.trimmingCharacters(in: .whitespacesAndNewlines)
            let pieces = trimmed.split(separator: " ").map(String.init)
            guard let deepest = pieces.last else { continue }

            var parents: [ScopeName]? = nil
            if pieces.count > 1 {
                parents = Array(pieces.dropLast()).reversed()
            }

            result.append(
                ParsedThemeRule(
                    scope: deepest,
                    parentScopes: parents,
                    index: idx,
                    fontStyle: fontStyle,
                    foreground: foreground,
                    background: background,
                    fontFamily: fontFamily,
                    fontSize: fontSize,
                    lineHeight: lineHeight
                ))
        }
    }

    return result
}

private func stripCommas(_ scope: String) -> String {
    var s = scope
    while s.first == "," { s.removeFirst() }
    while s.first?.isWhitespace == true { s.removeFirst() }
    while s.last == "," { s.removeLast() }
    while s.last?.isWhitespace == true { s.removeLast() }
    return s
}

public func resolveParsedThemeRules(_ parsed: [ParsedThemeRule], _ colorPreset: [String]?) -> Theme {
    var mutable = parsed

    mutable.sort { a, b in
        let c = tmStrcmp(a.scope, b.scope)
        if c != 0 { return c < 0 }
        let p = tmStrArrCmp(a.parentScopes, b.parentScopes)
        if p != 0 { return p < 0 }
        return a.index < b.index
    }

    var defaultFontStyle = FontStyle.none
    var defaultForeground = "#000000"
    var defaultBackground = "#ffffff"
    var defaultFontFamily = ""
    var defaultFontSize: Double = 0
    var defaultLineHeight: Double = 0

    while mutable.first?.scope == "" {
        let incoming = mutable.removeFirst()
        if incoming.fontStyle != FontStyle.notSet {
            defaultFontStyle = incoming.fontStyle
        }
        if let fg = incoming.foreground { defaultForeground = fg }
        if let bg = incoming.background { defaultBackground = bg }
        if !incoming.fontFamily.isEmpty { defaultFontFamily = incoming.fontFamily }
        if incoming.fontSize != 0 { defaultFontSize = incoming.fontSize }
        if incoming.lineHeight != 0 { defaultLineHeight = incoming.lineHeight }
    }

    let colorMap = TMColorMap(colorPreset)
    let defaults = StyleAttributes(
        fontStyle: defaultFontStyle,
        foregroundId: colorMap.getId(defaultForeground),
        backgroundId: colorMap.getId(defaultBackground),
        fontFamily: defaultFontFamily,
        fontSize: defaultFontSize,
        lineHeight: defaultLineHeight
    )

    let main = ThemeTrieElementRuleBox(
        scopeDepth: 0,
        parentScopes: nil,
        fontStyle: FontStyle.notSet,
        foreground: 0,
        background: 0,
        fontFamily: defaultFontFamily,
        fontSize: defaultFontSize,
        lineHeight: defaultLineHeight
    )

    let rootTrie = ThemeTrieElement(main, rulesWithParentScopes: [], children: [:])

    for rule in mutable {
        rootTrie.insert(
            scopeDepth: 0,
            scopeRemainder: rule.scope,
            parentScopes: rule.parentScopes,
            fontStyle: rule.fontStyle,
            foreground: colorMap.getId(rule.foreground),
            background: colorMap.getId(rule.background),
            fontFamily: rule.fontFamily,
            fontSize: rule.fontSize,
            lineHeight: rule.lineHeight
        )
    }

    return Theme(colorMapBundle: colorMap, defaultsBag: defaults, rootTrieBag: rootTrie)
}

private final class ThemeTrieCacheMatch {
    private var cache: [ScopeName: [ThemeTrieElementRuleBox]] = [:]
    func getCached(_ scopeName: ScopeName) -> [ThemeTrieElementRuleBox]? { cache[scopeName] }
    func put(_ scopeName: ScopeName, _ result: [ThemeTrieElementRuleBox]) { cache[scopeName] = result }
}

public final class Theme {
    private let colorMapBundle: TMColorMap
    private let defaultsBag: StyleAttributes
    private let rootTrieBag: ThemeTrieElement
    private let cacheRoots = ThemeTrieCacheMatch()

    init(colorMapBundle: TMColorMap, defaultsBag: StyleAttributes, rootTrieBag: ThemeTrieElement) {
        self.colorMapBundle = colorMapBundle
        self.defaultsBag = defaultsBag
        self.rootTrieBag = rootTrieBag
    }

    public static func createFromRawTheme(source: IRawTheme?, colorMap: [String]?) -> Theme {
        resolveParsedThemeRules(parseTheme(source: source), colorMap)
    }

    func getColorMap() -> [String] {
        colorMapBundle.palette()
    }

    func getDefaults() -> StyleAttributes {
        defaultsBag
    }

    func themeMatch(scopePath: ScopeStack?) -> StyleAttributes? {
        guard let scopePath else { return defaultsBag }
        let scopeNameLeaf = scopePath.scopeName

        let rules: [ThemeTrieElementRuleBox] = {
            if let cached = cacheRoots.getCached(scopeNameLeaf) {
                return cached
            }
            let produced = rootTrieBag.match(scopeNameLeaf)
            cacheRoots.put(scopeNameLeaf, produced)
            return produced
        }()

        guard let winner = rules.first(where: { _scopePathMatchesParentScopes(scopePath.parent, $0.parentScopes) }) else {
            return nil
        }

        return StyleAttributes(
            fontStyle: winner.fontStyleValue,
            foregroundId: winner.foreground,
            backgroundId: winner.background,
            fontFamily: winner.fontFamily,
            fontSize: winner.fontSize,
            lineHeight: winner.lineHeight
        )
    }
}
