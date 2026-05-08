// vscode-textmate `grammar/grammar.ts` (Grammar engine + tokenization helpers)

import Foundation

// MARK: - Theme / repository ports

public protocol TMGrammarThemeProvider: AnyObject {
    func themeMatch(scopePath: ScopeStack?) -> StyleAttributes?
    func getDefaults() -> StyleAttributes
}

public protocol TMGrammarRepositoryPort: AnyObject {
    func lookup(scopeName: ScopeName) -> IRawGrammar?
    func injections(forScope scopeName: ScopeName) -> [ScopeName]?
}

public typealias TMTokenTypeMap = [String: StandardTokenType]

// MARK: - Injection

public struct Injection {
    public let debugSelector: String
    public let matcher: (@Sendable ([String]) -> Bool)
    public let priority: Int
    public let ruleId: RuleId
    public let grammar: IRawGrammar
}

private final class GrammarInjectionRuleAdapter: IRawRule {
    let grammar: IRawGrammar
    init(_ grammar: IRawGrammar) { self.grammar = grammar }

    var id: RuleId?
    var vscodeTextmateLocation: ILocation? { grammar.vscodeTextmateLocation }
    var include: String? { nil }
    var name: String? { grammar.scopeName }
    var contentName: String? { nil }
    var match: String? { nil }
    var captures: IRawCaptures? { nil }
    var begin: String? { nil }
    var beginCaptures: IRawCaptures? { nil }
    var end: String? { nil }
    var endCaptures: IRawCaptures? { nil }
    var `while`: String? { nil }
    var whileCaptures: IRawCaptures? { nil }
    var patterns: [IRawRule]? { grammar.patterns }
    var repository: IRawRepository? { grammar.tmGrammarRepository }
    var applyEndPatternLast: Bool? { nil }
}

private func appendInjectionEntry(
    result: inout [Injection],
    selector: String,
    rule: IRawRule,
    helper: Grammar,
    grammar: IRawGrammar
) throws {
    let compiledRuleId = try RuleFactory.getCompiledRuleId(desc: rule, helper: helper, repository: grammar.tmGrammarRepository)
    for pair in createTmSelectors(selector, matchesName: tmNameMatcher) {
        result.append(
            Injection(
                debugSelector: selector,
                matcher: pair.matcher,
                priority: pair.priority,
                ruleId: compiledRuleId,
                grammar: grammar
            ))
    }
}

public struct TokenTypeMatcherBox {
    public let matcher: (@Sendable ([String]) -> Bool)
    public let type: StandardTokenType

    public init(matcher: @escaping @Sendable ([String]) -> Bool, type: StandardTokenType) {
        self.matcher = matcher
        self.type = type
    }
}

// MARK: - Font intervals

public final class TMFontInfo {
    public var startIndex: Int
    public var endIndex: Int
    public var fontFamily: String?
    public var fontSizeMultiplier: Double?
    public var lineHeightMultiplier: Double?

    public init(startIndex: Int, endIndex: Int, fontFamily: String?, fontSizeMultiplier: Double?, lineHeightMultiplier: Double?) {
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.fontFamily = fontFamily
        self.fontSizeMultiplier = fontSizeMultiplier
        self.lineHeightMultiplier = lineHeightMultiplier
    }

    public func optionsEqual(_ other: TMFontInfo) -> Bool {
        fontFamily == other.fontFamily
            && fontSizeMultiplier == other.fontSizeMultiplier
            && lineHeightMultiplier == other.lineHeightMultiplier
    }
}

public final class LineFonts {
    private var fonts: [TMFontInfo] = []
    private var lastIndex: Int = 0

    public init() {}

    public func produce(stack: StateStackImpl, endIndex: Int) {
        produceFromScopes(scopesList: stack.contentNameScopesList, endIndex: endIndex)
    }

    public func produceFromScopes(scopesList: AttributedScopeStack?, endIndex: Int) {
        guard let scopesList, let fa = scopesList.fontAttributes else {
            lastIndex = endIndex
            return
        }
        let fontFamily = fa.fontFamily
        let fontSizeMultiplier = fa.fontSize
        let lineHeightMultiplier = fa.lineHeight
        if fontFamily == nil && fontSizeMultiplier == nil && lineHeightMultiplier == nil {
            lastIndex = endIndex
            return
        }
        let font = TMFontInfo(
            startIndex: lastIndex,
            endIndex: endIndex,
            fontFamily: fontFamily,
            fontSizeMultiplier: fontSizeMultiplier,
            lineHeightMultiplier: lineHeightMultiplier
        )
        if let lastFont = fonts.last, lastFont.endIndex == lastIndex, lastFont.optionsEqual(font) {
            lastFont.endIndex = font.endIndex
        } else {
            fonts.append(font)
        }
        lastIndex = endIndex
    }

    public func getResult() -> [TMFontInfo] { fonts }
}

// MARK: - Balanced brackets

public final class BalancedBracketSelectors {
    private let balancedBracketScopesList: [([String]) -> Bool]
    private let unbalancedBracketScopesList: [([String]) -> Bool]
    private let allowAny: Bool

    public init(balancedBracketScopes: [String], unbalancedBracketScopes: [String]) {
        var bal: [([String]) -> Bool] = []
        var allowAnyLocal = false
        for selector in balancedBracketScopes {
            if selector == "*" {
                allowAnyLocal = true
                continue
            }
            for m in createTmSelectors(selector, matchesName: tmNameMatcher) {
                bal.append(m.matcher)
            }
        }
        allowAny = allowAnyLocal
        balancedBracketScopesList = bal

        unbalancedBracketScopesList = unbalancedBracketScopes.flatMap { sel in
            createTmSelectors(sel, matchesName: tmNameMatcher).map(\.matcher)
        }
    }

    public var matchesAlways: Bool {
        allowAny && unbalancedBracketScopesList.isEmpty
    }

    public var matchesNever: Bool {
        balancedBracketScopesList.isEmpty && !allowAny
    }

    public func match(scopes: [String]) -> Bool {
        for ex in unbalancedBracketScopesList where ex(scopes) {
            return false
        }
        for inc in balancedBracketScopesList where inc(scopes) {
            return true
        }
        return allowAny
    }
}

// MARK: - Line tokens

public final class LineTokens {
    private let emitBinaryTokens: Bool
    private let lineTextDebug: String?
    private var tokensLegacy: [LegacyToken] = []
    private var binaryTokens: [UInt32] = []
    private var lastTokenEndIndex: Int = 0
    private let tokenTypeOverrides: [TokenTypeMatcherBox]
    private let balancedBracketSelectors: BalancedBracketSelectors?
    private let mergeConsecutiveTokensWithEqualMetadata: Bool

    private struct LegacyToken {
        var startIndex: Int
        let endIndex: Int
        let scopes: [String]
    }

    public init(
        emitBinaryTokens: Bool,
        lineText: String,
        tokenTypeOverrides: [TokenTypeMatcherBox],
        balancedBracketSelectors: BalancedBracketSelectors?
    ) {
        self.emitBinaryTokens = emitBinaryTokens
        self.tokenTypeOverrides = tokenTypeOverrides
        self.balancedBracketSelectors = balancedBracketSelectors
        lineTextDebug = DebugFlags.inDebugMode ? lineText : nil
        mergeConsecutiveTokensWithEqualMetadata = !containsRTL(lineText)
    }

    convenience init(
        emitBinaryTokens: Bool,
        lineText: String,
        tokenTypeSelectors: TMTokenTypeMap?,
        balancedBracketSelectors: BalancedBracketSelectors?
    ) {
        var overrides: [TokenTypeMatcherBox] = []
        if let tokenTypeSelectors {
            for (selector, ty) in tokenTypeSelectors {
                for m in createTmSelectors(selector, matchesName: tmNameMatcher) {
                    overrides.append(TokenTypeMatcherBox(matcher: m.matcher, type: ty))
                }
            }
        }
        self.init(emitBinaryTokens: emitBinaryTokens, lineText: lineText, tokenTypeOverrides: overrides, balancedBracketSelectors: balancedBracketSelectors)
    }

    public func produce(stack: StateStackImpl, endIndex: Int) {
        produceFromScopes(scopesList: stack.contentNameScopesList, endIndex: endIndex)
    }

    public func produceFromScopes(scopesList: AttributedScopeStack?, endIndex: Int) {
        if lastTokenEndIndex >= endIndex { return }

        if emitBinaryTokens {
            var metadata = scopesList?.tokenAttributes ?? 0
            var containsBalancedBrackets = false

            if balancedBracketSelectors?.matchesAlways == true {
                containsBalancedBrackets = true
            }

            let needsScopes = !tokenTypeOverrides.isEmpty
                || (balancedBracketSelectors.map { !$0.matchesAlways && !$0.matchesNever } ?? false)

            var scopes: [String] = []
            if needsScopes {
                scopes = scopesList?.getScopeNames() ?? []
                for tokenType in tokenTypeOverrides where tokenType.matcher(scopes) {
                    metadata = EncodedTokenAttributes.set(
                        metadata,
                        languageId: 0,
                        tokenType: optional(from: tokenType.type),
                        balanced: nil,
                        fontStyleRaw: nil,
                        foreground: 0,
                        background: 0
                    )
                }
                if let bal = balancedBracketSelectors {
                    containsBalancedBrackets = bal.match(scopes: scopes)
                }
            }

            if containsBalancedBrackets {
                metadata = EncodedTokenAttributes.set(metadata, balanced: true)
            }

            if mergeConsecutiveTokensWithEqualMetadata,
               binaryTokens.count >= 2,
               binaryTokens[binaryTokens.count - 1] == metadata {
                lastTokenEndIndex = endIndex
                return
            }

            if DebugFlags.inDebugMode, let lt = lineTextDebug {
                let seg = substringUtf16(lt, lastTokenEndIndex, endIndex).replacingOccurrences(of: "\n", with: "\\n")
                print("  token: |\(seg)|")
                let sc = scopesList?.getScopeNames() ?? []
                for s in sc { print("      * \(s)") }
            }

            binaryTokens.append(UInt32(lastTokenEndIndex))
            binaryTokens.append(metadata)
            lastTokenEndIndex = endIndex
            return
        }

        let scopes = scopesList?.getScopeNames() ?? []

        if DebugFlags.inDebugMode, let lt = lineTextDebug {
            let seg = substringUtf16(lt, lastTokenEndIndex, endIndex).replacingOccurrences(of: "\n", with: "\\n")
            print("  token: |\(seg)|")
            for s in scopes { print("      * \(s)") }
        }

        tokensLegacy.append(LegacyToken(startIndex: lastTokenEndIndex, endIndex: endIndex, scopes: scopes))
        lastTokenEndIndex = endIndex
    }

    public func getBinaryResult(stack: StateStackImpl, lineLength: Int) -> [UInt32] {
        var bins = binaryTokens
        if bins.count >= 2, Int(bins[bins.count - 2]) == lineLength - 1 {
            bins.removeLast(2)
        }
        if bins.isEmpty {
            lastTokenEndIndex = -1
            produce(stack: stack, endIndex: lineLength)
            bins = binaryTokens
            if bins.count >= 2 {
                bins[bins.count - 2] = 0
            }
        }
        return bins
    }

    private func substringUtf16(_ s: String, _ start: Int, _ end: Int) -> String {
        let ns = s as NSString
        guard start <= end, start >= 0 else { return "" }
        return ns.substring(with: NSRange(location: start, length: max(0, end &- start)))
    }
}

private func fontStyleBits(_ fs: FontStyle) -> UInt32? {
    if fs == .notSet { return nil }
    return UInt32(fs.rawValue & 0xF)
}

// MARK: - Attributed scopes

public final class AttributedScopeStack {
    public let parent: AttributedScopeStack?
    public let scopePath: ScopeStack
    public let tokenAttributes: UInt32
    public let fontAttributes: FontAttribute?
    public let styleAttributes: StyleAttributes?

    public var scopeName: ScopeName { scopePath.scopeName }

    private init(
        parent: AttributedScopeStack?,
        scopePath: ScopeStack,
        tokenAttributes: UInt32,
        fontAttributes: FontAttribute?,
        styleAttributes: StyleAttributes?
    ) {
        self.parent = parent
        self.scopePath = scopePath
        self.tokenAttributes = tokenAttributes
        self.fontAttributes = fontAttributes
        self.styleAttributes = styleAttributes
    }

    public static func fromExtension(namesScopeList: AttributedScopeStack?, contentFrames: [AttributedScopeStackFrame]) -> AttributedScopeStack? {
        var current = namesScopeList
        var scopeNames: ScopeStack? = namesScopeList?.scopePath
        for frame in contentFrames {
            scopeNames = ScopeStack.push(scopeNames, frame.scopeNames)
            guard let path = scopeNames else { continue }
            current = AttributedScopeStack(
                parent: current,
                scopePath: path,
                tokenAttributes: frame.encodedTokenAttributes,
                fontAttributes: nil,
                styleAttributes: nil)
        }
        return current
    }

    public static func createRoot(scopeName: ScopeName, tokenAttributes: UInt32, fontAttribute: FontAttribute) -> AttributedScopeStack {
        AttributedScopeStack(parent: nil, scopePath: ScopeStack(nil, scopeName), tokenAttributes: tokenAttributes, fontAttributes: fontAttribute, styleAttributes: nil)
    }

    public static func createRootAndLookUpScopeName(
        scopeName: ScopeName,
        tokenAttributes: UInt32,
        fontAttribute: FontAttribute,
        grammar: Grammar
    ) -> AttributedScopeStack {
        let rawRootMetadata = grammar.basicScopeAttributesProvider.getBasicScopeAttributes(scopeName: scopeName)
        let scopePath = ScopeStack(nil, scopeName)
        let rootStyle = grammar.themeProvider.themeMatch(scopePath: scopePath)
        let resolvedTokenAttributes = mergeEncoded(existing: tokenAttributes, basic: rawRootMetadata, style: rootStyle)
        let resolvedFontAttributes = fontAttribute.with(rootStyle)
        return AttributedScopeStack(parent: nil, scopePath: scopePath, tokenAttributes: resolvedTokenAttributes, fontAttributes: resolvedFontAttributes, styleAttributes: rootStyle)
    }

    private static func mergeEncoded(existing: UInt32, basic: BasicScopeAttributes, style: StyleAttributes?) -> UInt32 {
        var fontStyle = FontStyle.notSet
        var fg: UInt32 = 0
        var bg: UInt32 = 0
        if let style {
            fontStyle = style.fontStyle
            fg = UInt32(style.foregroundId)
            bg = UInt32(style.backgroundId)
        }
        return EncodedTokenAttributes.set(
            existing,
            languageId: basic.languageId,
            tokenType: basic.tokenType,
            balanced: nil,
            fontStyleRaw: fontStyleBits(fontStyle),
            foreground: fg,
            background: bg
        )
    }

    public func pushAttributed(scopePath path: ScopeName?, grammar: Grammar) -> AttributedScopeStack {
        guard let path, !path.isEmpty else { return self }
        if !path.contains(where: { $0.isWhitespace }) {
            return Self.pushAttributedOne(target: self, scopeName: path, grammar: grammar)
        }
        let scopes = path.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var result: AttributedScopeStack = self
        for scope in scopes where !scope.isEmpty {
            result = Self.pushAttributedOne(target: result, scopeName: scope, grammar: grammar)
        }
        return result
    }

    private static func pushAttributedOne(target: AttributedScopeStack, scopeName: ScopeName, grammar: Grammar) -> AttributedScopeStack {
        let rawMetadata = grammar.basicScopeAttributesProvider.getBasicScopeAttributes(scopeName: scopeName)
        let newPath = target.scopePath.push(scopeName)
        let scopeThemeMatchResult = grammar.themeProvider.themeMatch(scopePath: newPath)
        let metadata = mergeEncoded(existing: target.tokenAttributes, basic: rawMetadata, style: scopeThemeMatchResult)
        let fontAttributes = target.fontAttributes?.with(scopeThemeMatchResult)
        return AttributedScopeStack(parent: target, scopePath: newPath, tokenAttributes: metadata, fontAttributes: fontAttributes, styleAttributes: scopeThemeMatchResult)
    }

    public func getScopeNames() -> [String] {
        scopePath.getSegments()
    }

    public func getExtensionIfDefined(base: AttributedScopeStack?) -> [AttributedScopeStackFrame]? {
        var result: [AttributedScopeStackFrame] = []
        var cur: AttributedScopeStack? = self
        while let c = cur, c !== base {
            let seg = c.scopePath.getExtensionIfDefined(base: c.parent?.scopePath) ?? []
            result.append(AttributedScopeStackFrame(encodedTokenAttributes: c.tokenAttributes, scopeNames: seg))
            cur = c.parent
        }
        return cur === base ? result.reversed() : nil
    }

    public static func equals(_ a: AttributedScopeStack?, _ b: AttributedScopeStack?) -> Bool {
        var x = a
        var y = b
        while true {
            if x === y { return true }
            if x == nil && y == nil { return true }
            guard let xa = x, let ya = y else { return false }
            if xa.scopeName != ya.scopeName || xa.tokenAttributes != ya.tokenAttributes { return false }
            x = xa.parent
            y = ya.parent
        }
    }
}

// MARK: - State stack

public final class StateStackImpl {
    private var enterPos: Int
    private var anchorPos: Int

    public let parent: StateStackImpl?
    private let ruleId: RuleId
    public let depth: Int

    public let beginRuleCapturedEOL: Bool
    public let endRule: String?

    public let nameScopesList: AttributedScopeStack?
    public let contentNameScopesList: AttributedScopeStack?

    public init(
        parent: StateStackImpl?,
        ruleId: RuleId,
        enterPos: Int,
        anchorPos: Int,
        beginRuleCapturedEOL: Bool,
        endRule: String?,
        nameScopesList: AttributedScopeStack?,
        contentNameScopesList: AttributedScopeStack?
    ) {
        self.parent = parent
        self.ruleId = ruleId
        self.enterPos = enterPos
        self.anchorPos = anchorPos
        self.beginRuleCapturedEOL = beginRuleCapturedEOL
        self.endRule = endRule
        self.nameScopesList = nameScopesList
        self.contentNameScopesList = contentNameScopesList
        depth = parent.map { $0.depth + 1 } ?? 1
    }

    public func getRule(_ grammar: Grammar) -> RuleBase {
        grammar.getRule(ruleId)
    }

    public func reset() {
        StateStackImpl.resetChain(self)
    }

    /// Rule id for this stack frame (must resolve on the `Grammar` that produced this stack).
    public var frameRuleId: RuleId { ruleId }

    private static func resetChain(_ el: StateStackImpl?) {
        var cur: StateStackImpl? = el
        while let c = cur {
            c.enterPos = -1
            c.anchorPos = -1
            cur = c.parent
        }
    }

    public func pop() -> StateStackImpl? { parent }

    public func safePop() -> StateStackImpl { parent ?? self }

    public func push(
        ruleId: RuleId,
        enterPos: Int,
        anchorPos: Int,
        beginRuleCapturedEOL: Bool,
        endRule: String?,
        nameScopesList: AttributedScopeStack?,
        contentNameScopesList: AttributedScopeStack?
    ) -> StateStackImpl {
        StateStackImpl(
            parent: self,
            ruleId: ruleId,
            enterPos: enterPos,
            anchorPos: anchorPos,
            beginRuleCapturedEOL: beginRuleCapturedEOL,
            endRule: endRule,
            nameScopesList: nameScopesList,
            contentNameScopesList: contentNameScopesList
        )
    }

    public func getEnterPos() -> Int { enterPos }
    public func getAnchorPos() -> Int { anchorPos }

    public func withContentNameScopesList(_ contentNameScopeStack: AttributedScopeStack) -> StateStackImpl {
        if contentNameScopesList === contentNameScopeStack { return self }
        guard let parent else { preconditionFailure("need parent") }
        return parent.push(
            ruleId: ruleId,
            enterPos: enterPos,
            anchorPos: anchorPos,
            beginRuleCapturedEOL: beginRuleCapturedEOL,
            endRule: endRule,
            nameScopesList: nameScopesList,
            contentNameScopesList: contentNameScopeStack
        )
    }

    public func withEndRule(_ endRule: String) -> StateStackImpl {
        if self.endRule == endRule { return self }
        return StateStackImpl(
            parent: parent,
            ruleId: ruleId,
            enterPos: enterPos,
            anchorPos: anchorPos,
            beginRuleCapturedEOL: beginRuleCapturedEOL,
            endRule: endRule,
            nameScopesList: nameScopesList,
            contentNameScopesList: contentNameScopesList
        )
    }

    public func hasSameRule(as other: StateStackImpl) -> Bool {
        var el: StateStackImpl? = self
        while let e = el, e.enterPos == other.enterPos {
            if e.ruleId == other.ruleId { return true }
            el = e.parent
        }
        return false
    }

    public func toStateStackFrame() -> StateStackFrame {
        let nameExt = nameScopesList?.getExtensionIfDefined(base: parent?.nameScopesList) ?? []
        let contentExt = contentNameScopesList?.getExtensionIfDefined(base: nameScopesList) ?? []
        return StateStackFrame(
            ruleId: ruleId.value,
            enterPos: enterPos,
            anchorPos: anchorPos,
            beginRuleCapturedEOL: beginRuleCapturedEOL,
            endRule: endRule,
            nameScopesList: nameExt,
            contentNameScopesList: contentExt
        )
    }

    public static func pushFrame(_ selfStack: StateStackImpl?, frame: StateStackFrame) -> StateStackImpl {
        let namesScopeList = AttributedScopeStack.fromExtension(namesScopeList: selfStack?.nameScopesList, contentFrames: frame.nameScopesList)!
        let contentList = AttributedScopeStack.fromExtension(namesScopeList: namesScopeList, contentFrames: frame.contentNameScopesList)!
        return StateStackImpl(
            parent: selfStack,
            ruleId: RuleId(frame.ruleId),
            enterPos: frame.enterPos ?? -1,
            anchorPos: frame.anchorPos ?? -1,
            beginRuleCapturedEOL: frame.beginRuleCapturedEOL,
            endRule: frame.endRule,
            nameScopesList: namesScopeList,
            contentNameScopesList: contentList
        )
    }

    private static func structuralEquals(_ a: StateStackImpl?, _ b: StateStackImpl?) -> Bool {
        var x = a
        var y = b
        while true {
            if x === y { return true }
            if x == nil && y == nil { return true }
            guard let xa = x, let ya = y else { return false }
            if xa.depth != ya.depth || xa.ruleId != ya.ruleId || xa.endRule != ya.endRule {
                return false
            }
            x = xa.parent
            y = ya.parent
        }
    }

    public func equals(_ other: StateStackImpl) -> Bool {
        Self.structuralEquals(self, other)
            && AttributedScopeStack.equals(contentNameScopesList, other.contentNameScopesList)
    }
}

extension AttributedScopeStack: CustomStringConvertible {
    public var description: String { getScopeNames().joined(separator: " ") }
}

// MARK: - Grammar

public struct TMTokenizeLineResult2 {
    public let tokens: [UInt32]
    public let ruleStack: StateStackImpl
    public let stoppedEarly: Bool
    public let fonts: [TMFontInfo]

    public init(tokens: [UInt32], ruleStack: StateStackImpl, stoppedEarly: Bool, fonts: [TMFontInfo]) {
        self.tokens = tokens
        self.ruleStack = ruleStack
        self.stoppedEarly = stoppedEarly
        self.fonts = fonts
    }
}

public func tmCreateGrammar(
    scopeName: ScopeName,
    grammar: IRawGrammar,
    initialLanguage: UInt32,
    embeddedLanguages: TMEmbeddedLanguagesMap?,
    tokenTypes: TMTokenTypeMap?,
    balancedBracketSelectors: BalancedBracketSelectors?,
    grammarRepository: TMGrammarRepositoryPort & TMGrammarThemeProvider,
    onigLib: IOnigLib
) -> Grammar {
    Grammar(
        rootScopeName: scopeName,
        grammar: grammar,
        initialLanguage: initialLanguage,
        embeddedLanguages: embeddedLanguages,
        tokenTypes: tokenTypes,
        balancedBracketSelectors: balancedBracketSelectors,
        grammarRepository: grammarRepository,
        onigLib: onigLib
    )
}

public final class Grammar: IRuleRegistry, IGrammarRegistry {
    private var rootId: RuleId?
    private var lastRuleId = 0
    private var ruleId2desc: [Int: RuleBase] = [:]
    private var includedGrammars: [String: IRawGrammar] = [:]

    private let grammarRepository: TMGrammarRepositoryPort & TMGrammarThemeProvider
    private let rawGrammar: IRawGrammar
    private let onigLib: IOnigLib
    private let balancedBracketSelectors: BalancedBracketSelectors?

    let basicScopeAttributesProvider: BasicScopeAttributesProvider

    private var injectionsMemo: [Injection]?
    private let tokenTypeMatchers: [TokenTypeMatcherBox]

    /// Raw rules currently inside `registerRule` for `getCompiledRuleId` (handles recursion before `ruleId2desc` is filled).
    private var rawRulesBeingCompiled: Set<ObjectIdentifier> = []

    private let rootScopeName: ScopeName

    public var themeProvider: TMGrammarThemeProvider { grammarRepository }

    public init(
        rootScopeName: ScopeName,
        grammar: IRawGrammar,
        initialLanguage: UInt32,
        embeddedLanguages: TMEmbeddedLanguagesMap?,
        tokenTypes: TMTokenTypeMap?,
        balancedBracketSelectors: BalancedBracketSelectors?,
        grammarRepository: TMGrammarRepositoryPort & TMGrammarThemeProvider,
        onigLib: IOnigLib
    ) {
        self.rootScopeName = rootScopeName
        rawGrammar = grammar
        self.grammarRepository = grammarRepository
        self.onigLib = onigLib
        self.balancedBracketSelectors = balancedBracketSelectors
        basicScopeAttributesProvider = BasicScopeAttributesProvider(initialLanguageId: initialLanguage, embeddedLanguages: embeddedLanguages)

        var matchers: [TokenTypeMatcherBox] = []
        if let tokenTypes {
            for (selector, ty) in tokenTypes {
                for m in createTmSelectors(selector, matchesName: tmNameMatcher) {
                    matchers.append(TokenTypeMatcherBox(matcher: m.matcher, type: ty))
                }
            }
        }
        tokenTypeMatchers = matchers
    }

    /// Drops compiled `RuleBase` rows, clears raw-rule `id` caches, and resets root/injection state.
    private func resetCompileArtifactsAndRawRuleIds() {
        clearRawGrammarCompileIdCache(rawGrammar)
        for g in includedGrammars.values {
            clearRawGrammarCompileIdCache(g)
        }
        for (_, rule) in ruleId2desc {
            rule.dispose()
        }
        ruleId2desc.removeAll()
        rawRulesBeingCompiled.removeAll()
        rootId = nil
        injectionsMemo = nil
        lastRuleId = 0
    }

    public func dispose() {
        resetCompileArtifactsAndRawRuleIds()
    }

    /// True if every frame’s `frameRuleId` exists in this grammar’s compiled rule map.
    public func ruleStackUsesKnownRules(_ stack: StateStackImpl?) -> Bool {
        guard let stack else { return true }
        var cur: StateStackImpl? = stack
        while let c = cur {
            if !hasCompiledRule(c.frameRuleId) { return false }
            cur = c.parent
        }
        return true
    }

    public func createOnigScanner(_ sources: [String]) throws -> OnigScannerProtocol {
        try onigLib.createOnigScanner(sources)
    }

    public func createOnigString(_ sources: String) -> OnigStringProtocol {
        onigLib.createOnigString(sources)
    }

    public func getMetadataForScope(scope: String) -> BasicScopeAttributes {
        basicScopeAttributesProvider.getBasicScopeAttributes(scopeName: scope)
    }

    public func registerRule<R: RuleBase>(_ factory: (RuleId) throws -> R) throws -> R {
        lastRuleId += 1
        let id = ruleIdFromNumber(lastRuleId)
        let result = try factory(id)
        ruleId2desc[id.value] = result
        return result
    }

    public func getRule(_ ruleId: RuleId) -> RuleBase {
        guard let r = ruleId2desc[ruleId.value] else {
            preconditionFailure("rule id \(ruleId.value) missing")
        }
        return r
    }

    public func getExternalGrammar(scopeName: String, repository: IRawRepository?) -> IRawGrammar? {
        if let cached = includedGrammars[scopeName] {
            return cached
        }
        guard let rawIncluded = grammarRepository.lookup(scopeName: scopeName) else {
            return nil
        }
        if let j = rawIncluded as? TMJSONGrammar {
            let baseRule = repository?.rawRule(forKey: "$base")
            let ready = tmInitGrammar(j, base: baseRule)
            includedGrammars[scopeName] = ready
            return ready
        }
        includedGrammars[scopeName] = rawIncluded
        return rawIncluded
    }

    private func buildInjectionsList() throws -> [Injection] {
        var result: [Injection] = []

        let grammar = rawGrammar

        if let rawInjections = grammar.grammarInjections {
            for (expression, rule) in rawInjections {
                try appendInjectionEntry(result: &result, selector: expression, rule: rule, helper: self, grammar: grammar)
            }
        }

        if let injectionScopeNames = grammarRepository.injections(forScope: rootScopeName) {
            for injectionScopeName in injectionScopeNames {
                if let injectionGrammar = getExternalGrammar(scopeName: injectionScopeName, repository: nil),
                   let selector = injectionGrammar.injectionSelector {
                    let adapter = GrammarInjectionRuleAdapter(injectionGrammar)
                    try appendInjectionEntry(result: &result, selector: selector, rule: adapter, helper: self, grammar: injectionGrammar)
                }
            }
        }

        result.sort { $0.priority < $1.priority }
        return result
    }

    public func getInjections() throws -> [Injection] {
        if let injectionsMemo { return injectionsMemo }
        let built = try buildInjectionsList()
        injectionsMemo = built
        return built
    }

    public func tokenizeLine2(lineText: String, prevState: StateStackImpl?, timeLimitMs: Int = 0) throws -> TMTokenizeLineResult2 {
        try ensureRootAndInjections()

        var prev = prevState
        if let s = prev, !ruleStackUsesKnownRules(s) {
            prev = nil
        }

        let isFresh = prev == nil

        var isFirstLine = false
        if isFresh {
            isFirstLine = true
            let rawDefaultMetadata = basicScopeAttributesProvider.getDefaultAttributes()
            let defaultStyle = grammarRepository.getDefaults()
            let defaultMetadata = EncodedTokenAttributes.set(
                0,
                languageId: rawDefaultMetadata.languageId,
                tokenType: rawDefaultMetadata.tokenType,
                balanced: nil,
                fontStyleRaw: fontStyleBits(defaultStyle.fontStyle),
                foreground: UInt32(defaultStyle.foregroundId),
                background: UInt32(defaultStyle.backgroundId)
            )
            let fontAttribute = FontAttribute.from(
                fontFamily: defaultStyle.fontFamily.isEmpty ? nil : defaultStyle.fontFamily,
                fontSize: defaultStyle.fontSize == 0 ? nil : defaultStyle.fontSize,
                lineHeight: defaultStyle.lineHeight == 0 ? nil : defaultStyle.lineHeight
            )

            let rootRule = getRule(rootId!)
            let rootScopeNameResolved = rootRule.getName(lineText: nil, captureIndices: nil)

            let scopeList: AttributedScopeStack = if let rootScopeNameResolved {
                AttributedScopeStack.createRootAndLookUpScopeName(
                    scopeName: rootScopeNameResolved,
                    tokenAttributes: defaultMetadata,
                    fontAttribute: fontAttribute,
                    grammar: self
                )
            } else {
                AttributedScopeStack.createRoot(scopeName: "unknown", tokenAttributes: defaultMetadata, fontAttribute: fontAttribute)
            }

            prev = StateStackImpl(
                parent: nil,
                ruleId: rootId!,
                enterPos: -1,
                anchorPos: -1,
                beginRuleCapturedEOL: false,
                endRule: nil,
                nameScopesList: scopeList,
                contentNameScopesList: scopeList
            )
        } else {
            prev?.reset()
            isFirstLine = false
        }

        let guardedPrev = prev!

        let lineWithNl = lineText + "\n"
        let onigLineText = createOnigString(lineWithNl)
        let lineLength = onigLineText.content.count

        let lineTokens = LineTokens(
            emitBinaryTokens: true,
            lineText: lineWithNl,
            tokenTypeOverrides: tokenTypeMatchers,
            balancedBracketSelectors: balancedBracketSelectors
        )

        let lineFonts = LineFonts()

        let r = try TMTokenizeString.run(
            grammar: self,
            lineText: onigLineText,
            isFirstLine: isFirstLine,
            linePos: 0,
            stack: guardedPrev,
            lineTokens: lineTokens,
            lineFonts: lineFonts,
            checkWhileConditions: true,
            timeLimitMs: timeLimitMs
        )

        let bins = lineTokens.getBinaryResult(stack: r.stack, lineLength: lineLength)

        return TMTokenizeLineResult2(
            tokens: bins,
            ruleStack: r.stack,
            stoppedEarly: r.stoppedEarly,
            fonts: lineFonts.getResult()
        )
    }

    private func ensureRootAndInjections() throws {
        if let rid = rootId, !hasCompiledRule(rid) {
            resetCompileArtifactsAndRawRuleIds()
        }
        if rootId != nil {
            if injectionsMemo == nil {
                do {
                    _ = try getInjections()
                } catch {
                    resetCompileArtifactsAndRawRuleIds()
                    throw error
                }
            }
            return
        }
        do {
            let rid = try RuleFactory.getCompiledRuleId(
                desc: rawGrammar.tmGrammarRepository.rawRule(forKey: "$self")!,
                helper: self,
                repository: rawGrammar.tmGrammarRepository
            )
            rootId = rid
            _ = try getInjections()
        } catch {
            resetCompileArtifactsAndRawRuleIds()
            throw error
        }
    }
}

extension Grammar: IRuleFactoryHelper {
    public func hasCompiledRule(_ id: RuleId) -> Bool {
        ruleId2desc[id.value] != nil
    }

    public func rawRuleCompileInProgress(_ desc: IRawRule) -> Bool {
        rawRulesBeingCompiled.contains(ObjectIdentifier(desc))
    }

    public func noteRawRuleCompileBegin(_ desc: IRawRule) {
        rawRulesBeingCompiled.insert(ObjectIdentifier(desc))
    }

    public func noteRawRuleCompileEnd(_ desc: IRawRule) {
        rawRulesBeingCompiled.remove(ObjectIdentifier(desc))
    }
}

extension Grammar: IOnigLib {}
