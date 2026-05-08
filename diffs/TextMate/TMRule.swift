// TMRule.swift — vscode-textmate `rule.ts` (Swift 5.9+). Pair with TMRegExpSource.swift.

import Foundation

// MARK: - Onig

public struct FindOption: RawRepresentable, OptionSet, Sendable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }
    public static let none = FindOption([])
    public static let notBeginString = FindOption(rawValue: 1)
    public static let notEndString = FindOption(rawValue: 2)
    public static let notBeginPosition = FindOption(rawValue: 4)
    public static let debugCall = FindOption(rawValue: 8)
}

public protocol IOnigCaptureIndex: Sendable {
    var start: Int { get }
    var end: Int { get }
    var length: Int { get }
}

public protocol IOnigMatch: Sendable {
    var index: Int { get }
    var captureIndices: [IOnigCaptureIndex] { get }
}

public protocol OnigStringProtocol: AnyObject {
    var content: String { get }
    func dispose()
}

public protocol OnigScannerProtocol: AnyObject {
    func findNextMatch(string: OnigStringProtocol, startPosition: Int, options: FindOption) -> IOnigMatch?
    func findNextMatch(string: String, startPosition: Int, options: FindOption) -> IOnigMatch?
    func dispose()
}

public protocol IOnigLib: AnyObject {
    func createOnigScanner(_ sources: [String]) throws -> OnigScannerProtocol
    func createOnigString(_ str: String) -> OnigStringProtocol
}

// MARK: - RuleId

public struct RuleId: Hashable, Sendable {
    public let value: Int
    public init(_ value: Int) { self.value = value }
}

public func ruleIdFromNumber(_ id: Int) -> RuleId { RuleId(id) }
public func ruleIdToNumber(_ id: RuleId) -> Int { id.value }

public let endRuleId: Int = -1
public let whileRuleId: Int = -2

// MARK: - Pattern slots (`RuleId | endRuleId` style)

public enum PatternRuleSlot: Equatable, Hashable, @unchecked Sendable {
    case rule(RuleId)
    case endMarker
    case whileMarker
}

extension RuleId {
    fileprivate func asPatternSlot() -> PatternRuleSlot { .rule(self) }
}

// MARK: - Raw grammar hooks

public struct ILocation: Hashable, Sendable {
    public let filename: String
    public let line: Int
    public let char: Int
    public init(filename: String, line: Int, char: Int) {
        self.filename = filename
        self.line = line
        self.char = char
    }
}

public protocol ILocatable: AnyObject {
    var vscodeTextmateLocation: ILocation? { get }
}

public protocol IRawRepository: ILocatable {
    func rawRule(forKey key: String) -> IRawRule?
    func allRepositoryKeys() -> [String]
}

public extension IRawRepository {
    func allRepositoryKeys() -> [String] { [] }
}

public protocol IRawGrammar: IRawRepository {
    var scopeName: String { get }
    var patterns: [IRawRule]? { get }
    var grammarInjections: [String: IRawRule]? { get }
    var injectionSelector: String? { get }
    /// The grammar's TextMate `repository` map (after `initGrammar`, includes `$self` / `$base`).
    var tmGrammarRepository: IRawRepository { get }
}

public extension IRawGrammar {
    var patterns: [IRawRule]? { nil }
    var grammarInjections: [String: IRawRule]? { nil }
    var injectionSelector: String? { nil }
    var tmGrammarRepository: IRawRepository { PlainMutableRepository() }
}

public protocol IRawCaptures: ILocatable {
    func allCaptureIds() -> [String]
    func captureRule(forId id: String) -> IRawRule?
}

public protocol IRawRule: AnyObject, ILocatable {
    var id: RuleId? { get set }
    var include: String? { get }
    var name: String? { get }
    var contentName: String? { get }
    var match: String? { get }
    var captures: IRawCaptures? { get }
    var begin: String? { get }
    var beginCaptures: IRawCaptures? { get }
    var end: String? { get }
    var endCaptures: IRawCaptures? { get }
    var `while`: String? { get }
    var whileCaptures: IRawCaptures? { get }
    var patterns: [IRawRule]? { get }
    var repository: IRawRepository? { get }
    var applyEndPatternLast: Bool? { get }
}

// MARK: - Raw rule compile cache (`desc.id` in vscode-textmate)

/// Clears `IRawRule.id` on a rule subgraph. Needed when a `Grammar` drops its `ruleId2desc` entries (e.g. `dispose()`)
/// while raw rule objects stay alive: otherwise `RuleFactory.getCompiledRuleId` returns stale ids with no registry row.
public func clearRawRuleCompileIdCache(on rule: IRawRule, visited: inout Set<ObjectIdentifier>) {
    let oid = ObjectIdentifier(rule)
    guard visited.insert(oid).inserted else { return }
    rule.id = nil

    func walkCaptures(_ captures: IRawCaptures?) {
        guard let captures else { return }
        for key in captures.allCaptureIds() where key != "$vscodeTextmateLocation" {
            guard let sub = captures.captureRule(forId: key) else { continue }
            clearRawRuleCompileIdCache(on: sub, visited: &visited)
        }
    }
    walkCaptures(rule.captures)
    walkCaptures(rule.beginCaptures)
    walkCaptures(rule.endCaptures)
    walkCaptures(rule.whileCaptures)

    if let patterns = rule.patterns {
        for p in patterns {
            clearRawRuleCompileIdCache(on: p, visited: &visited)
        }
    }
    if let repo = rule.repository {
        for key in repo.allRepositoryKeys() where key != "$vscodeTextmateLocation" {
            guard let sub = repo.rawRule(forKey: key) else { continue }
            clearRawRuleCompileIdCache(on: sub, visited: &visited)
        }
    }
}

/// Clears compile-id caches for an entire raw grammar (patterns, repository, injections).
public func clearRawGrammarCompileIdCache(_ grammar: IRawGrammar) {
    var visited: Set<ObjectIdentifier> = []
    if let patterns = grammar.patterns {
        for p in patterns {
            clearRawRuleCompileIdCache(on: p, visited: &visited)
        }
    }
    for key in grammar.tmGrammarRepository.allRepositoryKeys() where key != "$vscodeTextmateLocation" {
        guard let r = grammar.tmGrammarRepository.rawRule(forKey: key) else { continue }
        clearRawRuleCompileIdCache(on: r, visited: &visited)
    }
    if let injections = grammar.grammarInjections {
        for (_, r) in injections {
            clearRawRuleCompileIdCache(on: r, visited: &visited)
        }
    }
}

public enum RegexSource {
    public static func hasCaptures(_ regexSource: String?) -> Bool {
        guard let regexSource else { return false }
        guard let re = try? NSRegularExpression(pattern: #"\$(\d+)|\$\{(\d+):\/(downcase|upcase)\}"#, options: []) else {
            return false
        }
        let src = regexSource as NSString
        let range = NSRange(location: 0, length: src.length)
        return re.firstMatch(in: regexSource, options: [], range: range) != nil
    }

    public static func replaceCaptures(
        _ regexSource: String,
        captureSource: String,
        captureIndices: [IOnigCaptureIndex]
    ) -> String {
        guard let re = try? NSRegularExpression(pattern: #"\$(\d+)|\$\{(\d+):\/(downcase|upcase)\}"#, options: []) else {
            return regexSource
        }
        let src = regexSource as NSString
        let capString = captureSource as NSString
        let fullRange = NSRange(location: 0, length: src.length)
        var out = ""
        var last = 0
        re.enumerateMatches(in: regexSource, options: [], range: fullRange) { m, _, _ in
            guard let m else { return }
            if m.range.location > last {
                out.append(src.substring(with: NSRange(location: last, length: m.range.location - last)))
            }
            let d1 = m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound
                ? src.substring(with: m.range(at: 1)) : nil
            let d2 = m.numberOfRanges > 2 && m.range(at: 2).location != NSNotFound
                ? src.substring(with: m.range(at: 2)) : nil
            let cmd = m.numberOfRanges > 3 && m.range(at: 3).location != NSNotFound
                ? src.substring(with: m.range(at: 3)) : nil
            guard let idx = Int(d1 ?? d2 ?? ""), idx >= 0, idx < captureIndices.count else {
                last = m.range.location + m.range.length
                return
            }
            let c = captureIndices[idx]
            var piece = ""
            if c.start <= c.end, c.start >= 0, c.end <= capString.length {
                piece = capString.substring(with: NSRange(location: c.start, length: c.end - c.start))
            }
            while piece.first == "." { piece.removeFirst() }
            switch cmd {
            case "downcase": out += piece.lowercased()
            case "upcase": out += piece.uppercased()
            default: out += piece
            }
            last = m.range.location + m.range.length
        }
        if last < src.length {
            out.append(src.substring(from: last))
        }
        return out
    }
}

// MARK: Repository merge (`mergeObjects`)

private final class ShallowMergedRepository: IRawRepository {
    var vscodeTextmateLocation: ILocation?
    private let rules: [String: IRawRule]
    init(rules: [String: IRawRule], location: ILocation?) {
        self.rules = rules
        self.vscodeTextmateLocation = location
    }
    func rawRule(forKey key: String) -> IRawRule? { rules[key] }
    func allRepositoryKeys() -> [String] { Array(rules.keys) }
}

private func shallowMerge(_ base: IRawRepository, _ overlay: IRawRepository?) -> IRawRepository {
    guard let overlay else { return base }
    var map: [String: IRawRule] = [:]
    for k in base.allRepositoryKeys() where k != "$vscodeTextmateLocation" {
        map[k] = base.rawRule(forKey: k)
    }
    for k in overlay.allRepositoryKeys() where k != "$vscodeTextmateLocation" {
        map[k] = overlay.rawRule(forKey: k)
    }
    return ShallowMergedRepository(
        rules: map,
        location: overlay.vscodeTextmateLocation ?? base.vscodeTextmateLocation)
}

public final class PlainMutableRepository: IRawRepository {
    public var vscodeTextmateLocation: ILocation?
    private var storage: [String: IRawRule] = [:]
    public init(storage: [String: IRawRule] = [:], vscodeTextmateLocation: ILocation? = nil) {
        self.storage = storage
        self.vscodeTextmateLocation = vscodeTextmateLocation
    }
    public func rawRule(forKey key: String) -> IRawRule? { storage[key] }
    public func allRepositoryKeys() -> [String] { Array(storage.keys) }
    public func putRule(_ rule: IRawRule?, forKey key: String) { storage[key] = rule }
}

// MARK: Match result (`IFindNextMatchResult`)

public struct IFindNextMatchResult<TRuleId: Sendable>: Sendable {
    public let ruleId: TRuleId
    public let captureIndices: [IOnigCaptureIndex]
    public init(ruleId: TRuleId, captureIndices: [IOnigCaptureIndex]) {
        self.ruleId = ruleId
        self.captureIndices = captureIndices
    }
}

// MARK: Registries

public protocol IRuleRegistry: AnyObject {
    func getRule(_ ruleId: RuleId) -> RuleBase
    func registerRule<R: RuleBase>(_ factory: (RuleId) throws -> R) throws -> R
    func hasCompiledRule(_ id: RuleId) -> Bool
}

public protocol IGrammarRegistry: AnyObject {
    func getExternalGrammar(scopeName: String, repository: IRawRepository?) -> IRawGrammar?
}

public protocol IRuleFactoryHelper: IRuleRegistry, IGrammarRegistry {
    /// True while `registerRule`'s factory is building this raw rule (recursion must return `desc.id` before the row exists).
    func rawRuleCompileInProgress(_ desc: IRawRule) -> Bool
    func noteRawRuleCompileBegin(_ desc: IRawRule)
    func noteRawRuleCompileEnd(_ desc: IRawRule)
}

public protocol ICompilePatternsResult: Sendable {
    var patterns: [RuleId] { get }
    var hasMissingPatterns: Bool { get }
}

private struct CompilePatternsResult: ICompilePatternsResult {
    let patterns: [RuleId]
    let hasMissingPatterns: Bool
}

private final class IncludeStubRule: IRawRule {
    var id: RuleId?
    private let inc: String
    init(_ include: String) { self.inc = include }
    var vscodeTextmateLocation: ILocation? { nil }
    var include: String? { inc }
    var name: String? { nil }
    var contentName: String? { nil }
    var match: String? { nil }
    var captures: IRawCaptures? { nil }
    var begin: String? { nil }
    var beginCaptures: IRawCaptures? { nil }
    var end: String? { nil }
    var endCaptures: IRawCaptures? { nil }
    var `while`: String? { nil }
    var whileCaptures: IRawCaptures? { nil }
    var patterns: [IRawRule]? { nil }
    var repository: IRawRepository? { nil }
    var applyEndPatternLast: Bool? { nil }
}

// MARK: - Rule hierarchy

public class RuleBase {
    public let location: ILocation?
    public let id: RuleId
    private let nameIsCapturing: Bool
    private let name: String?
    private let contentNameIsCapturing: Bool
    private let contentName: String?

    public init(location: ILocation?, id: RuleId, name: String?, contentName: String?) {
        self.location = location
        self.id = id
        self.name = name
        self.nameIsCapturing = RegexSource.hasCaptures(name)
        self.contentName = contentName
        self.contentNameIsCapturing = RegexSource.hasCaptures(contentName)
    }

    open func dispose() {}

    public var debugName: String {
        let loc = location.map { "\(textMateBasename($0.filename)):\($0.line)" } ?? "unknown"
        return "\(String(describing: type(of: self)))#\(id.value) @ \(loc)"
    }

    public func getName(lineText: String?, captureIndices: [IOnigCaptureIndex]?) -> String? {
        guard nameIsCapturing, let name, let lineText, let captureIndices else { return name }
        return RegexSource.replaceCaptures(name, captureSource: lineText, captureIndices: captureIndices)
    }

    public func getContentName(lineText: String, captureIndices: [IOnigCaptureIndex]) -> String? {
        guard contentNameIsCapturing, let contentName else { return contentName }
        return RegexSource.replaceCaptures(contentName, captureSource: lineText, captureIndices: captureIndices)
    }

    open func collectPatterns(grammar: IRuleRegistry, out: RegExpSourceList<PatternRuleSlot>) {
        preconditionFailure("abstract \(type(of: self))")
    }

    open func compile(grammar: IRuleRegistry & IOnigLib, endRegexSource: String?) throws -> CompiledRule<PatternRuleSlot> {
        preconditionFailure("abstract \(type(of: self))")
    }

    open func compileAG(
        grammar: IRuleRegistry & IOnigLib,
        endRegexSource: String?,
        allowA: Bool,
        allowG: Bool
    ) throws -> CompiledRule<PatternRuleSlot> {
        preconditionFailure("abstract \(type(of: self))")
    }
}

public final class CaptureRule: RuleBase {
    public let retokenizeCapturedWithRuleId: RuleId?
    public init(
        location: ILocation?,
        id: RuleId,
        name: String?,
        contentName: String?,
        retokenizeCapturedWithRuleId: RuleId?
    ) {
        self.retokenizeCapturedWithRuleId = retokenizeCapturedWithRuleId
        super.init(location: location, id: id, name: name, contentName: contentName)
    }
    public override func collectPatterns(grammar: IRuleRegistry, out: RegExpSourceList<PatternRuleSlot>) {
        preconditionFailure("Not supported!")
    }
    public override func compile(grammar: IRuleRegistry & IOnigLib, endRegexSource: String?) throws -> CompiledRule<PatternRuleSlot> {
        preconditionFailure("Not supported!")
    }
    public override func compileAG(
        grammar: IRuleRegistry & IOnigLib,
        endRegexSource: String?,
        allowA: Bool,
        allowG: Bool
    ) throws -> CompiledRule<PatternRuleSlot> {
        preconditionFailure("Not supported!")
    }
}

public final class MatchRule: RuleBase {
    private let item: RegExpSourceItem<PatternRuleSlot>
    public let captures: [CaptureRule?]
    private var cached: RegExpSourceList<PatternRuleSlot>?

    public init(location: ILocation?, id: RuleId, name: String?, match: String, captures: [CaptureRule?]) {
        self.item = RegExpSourceItem(match, ruleId: id.asPatternSlot())
        self.captures = captures
        super.init(location: location, id: id, name: name, contentName: nil)
    }

    public override func dispose() {
        cached?.dispose()
        cached = nil
    }

    public var debugMatchRegExp: String { item.source }

    public override func collectPatterns(grammar: IRuleRegistry, out: RegExpSourceList<PatternRuleSlot>) {
        out.push(item)
    }

    public override func compile(grammar: IRuleRegistry & IOnigLib, endRegexSource: String?) throws -> CompiledRule<PatternRuleSlot> {
        try list(grammar).compile(onigLib: grammar)
    }

    public override func compileAG(
        grammar: IRuleRegistry & IOnigLib,
        endRegexSource: String?,
        allowA: Bool,
        allowG: Bool
    ) throws -> CompiledRule<PatternRuleSlot> {
        try list(grammar).compileAG(onigLib: grammar, allowA: allowA, allowG: allowG)
    }

    private func list(_ grammar: IRuleRegistry & IOnigLib) throws -> RegExpSourceList<PatternRuleSlot> {
        if cached == nil {
            let l = RegExpSourceList<PatternRuleSlot>()
            collectPatterns(grammar: grammar, out: l)
            cached = l
        }
        return cached!
    }
}

public final class IncludeOnlyRule: RuleBase {
    public let hasMissingPatterns: Bool
    public let patterns: [RuleId]
    private var cached: RegExpSourceList<PatternRuleSlot>?

    public init(location: ILocation?, id: RuleId, name: String?, contentName: String?, patterns: ICompilePatternsResult) {
        self.patterns = patterns.patterns
        self.hasMissingPatterns = patterns.hasMissingPatterns
        super.init(location: location, id: id, name: name, contentName: contentName)
    }

    public override func dispose() {
        cached?.dispose()
        cached = nil
    }

    public override func collectPatterns(grammar: IRuleRegistry, out: RegExpSourceList<PatternRuleSlot>) {
        for p in patterns {
            guard grammar.hasCompiledRule(p) else { continue }
            grammar.getRule(p).collectPatterns(grammar: grammar, out: out)
        }
    }

    public override func compile(grammar: IRuleRegistry & IOnigLib, endRegexSource: String?) throws -> CompiledRule<PatternRuleSlot> {
        try list(grammar).compile(onigLib: grammar)
    }

    public override func compileAG(
        grammar: IRuleRegistry & IOnigLib,
        endRegexSource: String?,
        allowA: Bool,
        allowG: Bool
    ) throws -> CompiledRule<PatternRuleSlot> {
        try list(grammar).compileAG(onigLib: grammar, allowA: allowA, allowG: allowG)
    }

    private func list(_ grammar: IRuleRegistry & IOnigLib) throws -> RegExpSourceList<PatternRuleSlot> {
        if cached == nil {
            let l = RegExpSourceList<PatternRuleSlot>()
            collectPatterns(grammar: grammar, out: l)
            cached = l
        }
        return cached!
    }
}

public final class BeginEndRule: RuleBase {
    private let beginItem: RegExpSourceItem<PatternRuleSlot>
    public let beginCaptures: [CaptureRule?]
    private let endItem: RegExpSourceItem<PatternRuleSlot>
    public let endHasBackReferences: Bool
    public let endCaptures: [CaptureRule?]
    public let applyEndPatternLast: Bool
    public let hasMissingPatterns: Bool
    public let patterns: [RuleId]
    private var cached: RegExpSourceList<PatternRuleSlot>?

    public init(
        location: ILocation?,
        id: RuleId,
        name: String?,
        contentName: String?,
        begin: String,
        beginCaptures: [CaptureRule?],
        end: String?,
        endCaptures: [CaptureRule?],
        applyEndPatternLast: Bool?,
        patterns: ICompilePatternsResult
    ) {
        self.beginItem = RegExpSourceItem(begin, ruleId: id.asPatternSlot())
        self.beginCaptures = beginCaptures
        self.endItem = RegExpSourceItem(end ?? "", ruleId: .endMarker)
        self.endHasBackReferences = self.endItem.hasBackReferences
        self.endCaptures = endCaptures
        self.applyEndPatternLast = applyEndPatternLast ?? false
        self.patterns = patterns.patterns
        self.hasMissingPatterns = patterns.hasMissingPatterns
        super.init(location: location, id: id, name: name, contentName: contentName)
    }

    public override func dispose() {
        cached?.dispose()
        cached = nil
    }

    public var debugBeginRegExp: String { beginItem.source }
    public var debugEndRegExp: String { endItem.source }

    public func getEndWithResolvedBackReferences(lineText: String, captureIndices: [IOnigCaptureIndex]) -> String {
        endItem.resolveBackReferences(lineText: lineText, captureIndices: captureIndices)
    }

    public override func collectPatterns(grammar: IRuleRegistry, out: RegExpSourceList<PatternRuleSlot>) {
        out.push(beginItem)
    }

    public override func compile(grammar: IRuleRegistry & IOnigLib, endRegexSource: String?) throws -> CompiledRule<PatternRuleSlot> {
        try resolveCache(grammar, endRegexSource ?? "").compile(onigLib: grammar)
    }

    public override func compileAG(
        grammar: IRuleRegistry & IOnigLib,
        endRegexSource: String?,
        allowA: Bool,
        allowG: Bool
    ) throws -> CompiledRule<PatternRuleSlot> {
        try resolveCache(grammar, endRegexSource ?? "").compileAG(onigLib: grammar, allowA: allowA, allowG: allowG)
    }

    private func resolveCache(_ grammar: IRuleRegistry & IOnigLib, _ endResolved: String) throws -> RegExpSourceList<PatternRuleSlot> {
        if cached == nil {
            let l = RegExpSourceList<PatternRuleSlot>()
            for p in patterns {
                guard grammar.hasCompiledRule(p) else { continue }
                grammar.getRule(p).collectPatterns(grammar: grammar, out: l)
            }
            if applyEndPatternLast {
                l.push(endHasBackReferences ? endItem.clone() : endItem)
            } else {
                l.unshift(endHasBackReferences ? endItem.clone() : endItem)
            }
            cached = l
        }
        let l = cached!
        if endHasBackReferences {
            if applyEndPatternLast {
                l.setSource(index: l.length() - 1, newSource: endResolved)
            } else {
                l.setSource(index: 0, newSource: endResolved)
            }
        }
        return l
    }
}

public final class BeginWhileRule: RuleBase {
    public enum WhilePatternSlot: Equatable, Hashable, @unchecked Sendable {
        case rule(RuleId)
        case whileMarker
    }

    private let beginItem: RegExpSourceItem<PatternRuleSlot>
    public let beginCaptures: [CaptureRule?]
    public let whileCaptures: [CaptureRule?]
    private let whileItem: RegExpSourceItem<WhilePatternSlot>
    public let whileHasBackReferences: Bool
    public let hasMissingPatterns: Bool
    public let patterns: [RuleId]
    private var cachedMain: RegExpSourceList<PatternRuleSlot>?
    private var cachedWhile: RegExpSourceList<WhilePatternSlot>?

    public init(
        location: ILocation?,
        id: RuleId,
        name: String?,
        contentName: String?,
        begin: String,
        beginCaptures: [CaptureRule?],
        while whilePart: String,
        whileCaptures: [CaptureRule?],
        patterns: ICompilePatternsResult
    ) {
        self.beginItem = RegExpSourceItem(begin, ruleId: id.asPatternSlot())
        self.beginCaptures = beginCaptures
        self.whileCaptures = whileCaptures
        self.whileItem = RegExpSourceItem(whilePart, ruleId: .whileMarker)
        self.whileHasBackReferences = whileItem.hasBackReferences
        self.patterns = patterns.patterns
        self.hasMissingPatterns = patterns.hasMissingPatterns
        super.init(location: location, id: id, name: name, contentName: contentName)
    }

    public override func dispose() {
        cachedMain?.dispose()
        cachedMain = nil
        cachedWhile?.dispose()
        cachedWhile = nil
    }

    public var debugBeginRegExp: String { beginItem.source }
    public var debugWhileRegExp: String { whileItem.source }

    public func getWhileWithResolvedBackReferences(lineText: String, captureIndices: [IOnigCaptureIndex]) -> String {
        whileItem.resolveBackReferences(lineText: lineText, captureIndices: captureIndices)
    }

    public override func collectPatterns(grammar: IRuleRegistry, out: RegExpSourceList<PatternRuleSlot>) {
        out.push(beginItem)
    }

    public override func compile(grammar: IRuleRegistry & IOnigLib, endRegexSource: String?) throws -> CompiledRule<PatternRuleSlot> {
        try mainList(grammar).compile(onigLib: grammar)
    }

    public override func compileAG(
        grammar: IRuleRegistry & IOnigLib,
        endRegexSource: String?,
        allowA: Bool,
        allowG: Bool
    ) throws -> CompiledRule<PatternRuleSlot> {
        try mainList(grammar).compileAG(onigLib: grammar, allowA: allowA, allowG: allowG)
    }

    public func compileWhile(grammar: IRuleRegistry & IOnigLib, endRegexSource: String?) throws -> CompiledRule<WhilePatternSlot> {
        try whileList(grammar, endRegexSource ?? "").compile(onigLib: grammar)
    }

    public func compileWhileAG(
        grammar: IRuleRegistry & IOnigLib,
        endRegexSource: String?,
        allowA: Bool,
        allowG: Bool
    ) throws -> CompiledRule<WhilePatternSlot> {
        try whileList(grammar, endRegexSource ?? "").compileAG(onigLib: grammar, allowA: allowA, allowG: allowG)
    }

    private func mainList(_ grammar: IRuleRegistry & IOnigLib) throws -> RegExpSourceList<PatternRuleSlot> {
        if cachedMain == nil {
            let l = RegExpSourceList<PatternRuleSlot>()
            for p in patterns {
                guard grammar.hasCompiledRule(p) else { continue }
                grammar.getRule(p).collectPatterns(grammar: grammar, out: l)
            }
            cachedMain = l
        }
        return cachedMain!
    }

    private func whileList(_ _: IRuleRegistry & IOnigLib, _ endResolved: String) throws -> RegExpSourceList<WhilePatternSlot> {
        if cachedWhile == nil {
            let l = RegExpSourceList<WhilePatternSlot>()
            l.push(whileHasBackReferences ? whileItem.clone() : whileItem)
            cachedWhile = l
        }
        let l = cachedWhile!
        if whileHasBackReferences {
            l.setSource(index: 0, newSource: endResolved)
        }
        return l
    }
}

// MARK: RuleFactory

public enum RuleFactory {
    public static func createCaptureRule(
        helper: IRuleFactoryHelper,
        location: ILocation?,
        name: String?,
        contentName: String?,
        retokenizeCapturedWithRuleId: RuleId?
    ) throws -> CaptureRule {
        try helper.registerRule { id in
            CaptureRule(
                location: location,
                id: id,
                name: name,
                contentName: contentName,
                retokenizeCapturedWithRuleId: retokenizeCapturedWithRuleId)
        }
    }

    public static func getCompiledRuleId(desc: IRawRule, helper: IRuleFactoryHelper, repository: IRawRepository) throws -> RuleId {
        if let existing = desc.id {
            if helper.hasCompiledRule(existing) { return existing }
            if helper.rawRuleCompileInProgress(desc) { return existing }
        }
        // Stale `desc.id` (another `Grammar` on the same raw graph, or after `dispose` if cache was not cleared).
        if desc.id != nil { desc.id = nil }
        // Match to-port/vscode-textmate `rule.ts`: set `desc.id` before `_compileCaptures` / `_compilePatterns`
        // so recursive `getCompiledRuleId(desc, …)` (same raw rule) returns immediately. If compilation throws,
        // clear `desc.id` so we do not leave an id with no row in `ruleId2desc` (registerRule does not store on throw).
        let result = try helper.registerRule { id in
            helper.noteRawRuleCompileBegin(desc)
            desc.id = id
            defer { helper.noteRawRuleCompileEnd(desc) }
            do {
                if let m = desc.match {
                    return MatchRule(
                        location: desc.vscodeTextmateLocation,
                        id: id,
                        name: desc.name,
                        match: m,
                        captures: try compileCaptures(desc.captures, helper: helper, repository: repository))
                }
                guard let _ = desc.begin else {
                    var repo = repository
                    if let o = desc.repository { repo = shallowMerge(repository, o) }
                    var plist = desc.patterns
                    if plist == nil, let inc = desc.include {
                        plist = [IncludeStubRule(inc)]
                    }
                    return IncludeOnlyRule(
                        location: desc.vscodeTextmateLocation,
                        id: id,
                        name: desc.name,
                        contentName: desc.contentName,
                        patterns: try compilePatterns(plist, helper: helper, repository: repo))
                }
                var repo = repository
                if let o = desc.repository { repo = shallowMerge(repository, o) }
                if let wPart = desc.`while` {
                    return BeginWhileRule(
                        location: desc.vscodeTextmateLocation,
                        id: id,
                        name: desc.name,
                        contentName: desc.contentName,
                        begin: desc.begin!,
                        beginCaptures: try compileCaptures(desc.beginCaptures ?? desc.captures, helper: helper, repository: repo),
                        while: wPart,
                        whileCaptures: try compileCaptures(desc.whileCaptures ?? desc.captures, helper: helper, repository: repo),
                        patterns: try compilePatterns(desc.patterns, helper: helper, repository: repo))
                }
                return BeginEndRule(
                    location: desc.vscodeTextmateLocation,
                    id: id,
                    name: desc.name,
                    contentName: desc.contentName,
                    begin: desc.begin!,
                    beginCaptures: try compileCaptures(desc.beginCaptures ?? desc.captures, helper: helper, repository: repo),
                    end: desc.end,
                    endCaptures: try compileCaptures(desc.endCaptures ?? desc.captures, helper: helper, repository: repo),
                    applyEndPatternLast: desc.applyEndPatternLast,
                    patterns: try compilePatterns(desc.patterns, helper: helper, repository: repo))
            } catch {
                desc.id = nil
                throw error
            }
        }
        return result.id
    }

    private static func compileCaptures(
        _ captures: IRawCaptures?,
        helper: IRuleFactoryHelper,
        repository: IRawRepository
    ) throws -> [CaptureRule?] {
        guard let captures else { return [] }
        var maxId = 0
        for key in captures.allCaptureIds() where key != "$vscodeTextmateLocation" {
            if let n = Int(key), n > maxId { maxId = n }
        }
        var result: [CaptureRule?] = Array(repeating: nil, count: maxId + 1)
        for key in captures.allCaptureIds() {
            guard key != "$vscodeTextmateLocation",
                  let n = Int(key),
                  let capDesc = captures.captureRule(forId: key) else { continue }
            var retok: RuleId? = nil
            if capDesc.patterns != nil {
                retok = try getCompiledRuleId(desc: capDesc, helper: helper, repository: repository)
            }
            let cr = try createCaptureRule(
                helper: helper,
                location: capDesc.vscodeTextmateLocation,
                name: capDesc.name,
                contentName: capDesc.contentName,
                retokenizeCapturedWithRuleId: retok)
            if n < result.count {
                result[n] = cr
            }
        }
        return result
    }

    private static func compilePatterns(
        _ patterns: [IRawRule]?,
        helper: IRuleFactoryHelper,
        repository: IRawRepository
    ) throws -> CompilePatternsResult {
        var r: [RuleId] = []
        if let patterns {
            outer: for pat in patterns {
                var cand: RuleId?
                if let include = pat.include {
                    let ref = parseInclude(include)
                    switch ref {
                    case .base, .`self`:
                        guard let sub = repository.rawRule(forKey: include) else { continue outer }
                        cand = try getCompiledRuleId(desc: sub, helper: helper, repository: repository)
                    case .relativeReference(let ruleName):
                        guard let sub = repository.rawRule(forKey: ruleName) else { continue outer }
                        cand = try getCompiledRuleId(desc: sub, helper: helper, repository: repository)
                    case .topLevelReference(let scope):
                        guard let g = helper.getExternalGrammar(scopeName: scope, repository: repository),
                              let sub = g.rawRule(forKey: "$self") else { continue outer }
                        cand = try getCompiledRuleId(desc: sub, helper: helper, repository: g)
                    case .topLevelRepositoryReference(let scope, let ruleName):
                        guard let g = helper.getExternalGrammar(scopeName: scope, repository: repository),
                              let sub = g.rawRule(forKey: ruleName) else { continue outer }
                        cand = try getCompiledRuleId(desc: sub, helper: helper, repository: g)
                    }
                } else {
                    cand = try getCompiledRuleId(desc: pat, helper: helper, repository: repository)
                }
                guard let rid = cand else { continue }
                if !helper.hasCompiledRule(rid) {
                    // Recursive references can return an in-progress id before `registerRule`
                    // has stored the final row in the grammar registry.
                    r.append(rid)
                    continue
                }
                let rule = helper.getRule(rid)
                if let i = rule as? IncludeOnlyRule, i.hasMissingPatterns, i.patterns.isEmpty { continue }
                if let b = rule as? BeginEndRule, b.hasMissingPatterns, b.patterns.isEmpty { continue }
                if let w = rule as? BeginWhileRule, w.hasMissingPatterns, w.patterns.isEmpty { continue }
                r.append(rid)
            }
        }
        return CompilePatternsResult(patterns: r, hasMissingPatterns: ((patterns?.count ?? 0) != r.count))
    }
}
