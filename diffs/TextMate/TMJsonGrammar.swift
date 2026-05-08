// Decodes TextMate grammar JSON into object-graph implementing `IRawGrammar`,
// then applies vscode-textmate `initGrammar` (`$self` / `$base` repository entries).

import Foundation

// MARK: - Captures

private final class JsonCaptures: IRawCaptures {
    var vscodeTextmateLocation: ILocation?
    private let backing: [String: JsonRawRule]

    init(dict: [String: Any]) throws {
        var rules: [String: JsonRawRule] = [:]
        for (k, v) in dict where k != "$vscodeTextmateLocation" {
            guard let sub = v as? [String: Any] else { continue }
            rules[k] = try JsonRawRule.decode(from: sub)
        }
        backing = rules
    }

    func allCaptureIds() -> [String] { Array(backing.keys) }

    func captureRule(forId id: String) -> IRawRule? { backing[id] }
}

// MARK: - Rule

private func optString(_ dict: [String: Any], _ key: String) -> String? {
    dict[key] as? String
}

private func optBool(_ dict: [String: Any], _ key: String) -> Bool? {
    dict[key] as? Bool
}

/// Leaf JSON rule object (also used inside repository / patterns arrays).
public final class JsonRawRule: IRawRule {
    public var id: RuleId?
    public var vscodeTextmateLocation: ILocation?
    public var include: String?
    public var name: String?
    public var contentName: String?
    public var match: String?
    public var captures: IRawCaptures?
    public var begin: String?
    public var beginCaptures: IRawCaptures?
    public var end: String?
    public var endCaptures: IRawCaptures?
    public var `while`: String?
    public var whileCaptures: IRawCaptures?
    public var patterns: [IRawRule]?
    public var repository: IRawRepository?
    public var applyEndPatternLast: Bool?

    static func decode(from dict: [String: Any]) throws -> JsonRawRule {
        let rule = JsonRawRule()
        rule.include = optString(dict, "include")
        rule.name = optString(dict, "name")
        rule.contentName = optString(dict, "contentName")
        rule.match = optString(dict, "match")
        rule.begin = optString(dict, "begin")
        rule.end = optString(dict, "end")
        rule.`while` = optString(dict, "while")
        rule.applyEndPatternLast = optBool(dict, "applyEndPatternLast")

        if let c = dict["captures"] as? [String: Any] {
            rule.captures = try JsonCaptures(dict: c)
        }
        if let c = dict["beginCaptures"] as? [String: Any] {
            rule.beginCaptures = try JsonCaptures(dict: c)
        }
        if let c = dict["endCaptures"] as? [String: Any] {
            rule.endCaptures = try JsonCaptures(dict: c)
        }
        if let c = dict["whileCaptures"] as? [String: Any] {
            rule.whileCaptures = try JsonCaptures(dict: c)
        }

        if let repoDict = dict["repository"] as? [String: Any] {
            rule.repository = try decodeRepository(repoDict)
        }

        if let plist = dict["patterns"] as? [[String: Any]] {
            rule.patterns = try plist.map { try decode(from: $0) }
        }

        return rule
    }
}

private func decodeRepository(_ dict: [String: Any]) throws -> PlainMutableRepository {
    let repo = PlainMutableRepository()
    for (k, v) in dict where k != "$vscodeTextmateLocation" {
        guard let ruleDict = v as? [String: Any] else { continue }
        repo.putRule(try JsonRawRule.decode(from: ruleDict), forKey: k)
    }
    return repo
}

// MARK: - Grammar document

/// Grammar decoded from JSON (before `tmInitGrammar`).
public final class TMJSONGrammar: IRawGrammar {
    public let scopeName: String
    public private(set) var patterns: [IRawRule]?
    public private(set) var grammarInjections: [String: IRawRule]?
    public var injectionSelector: String?
    public var vscodeTextmateLocation: ILocation?

    private let jsonRepository: PlainMutableRepository

    /// After `tmInitGrammar`, includes `$self` / `$base` required by `RuleFactory`.
    public private(set) var tmGrammarRepository: IRawRepository

    public init(scopeName: String, patterns: [IRawRule]?, injections: [String: IRawRule]?, injectionSelector: String?, repository: PlainMutableRepository) {
        self.scopeName = scopeName
        self.patterns = patterns
        self.grammarInjections = injections
        self.injectionSelector = injectionSelector
        self.jsonRepository = repository
        self.tmGrammarRepository = PlainMutableRepository()
    }

    public func rawRule(forKey key: String) -> IRawRule? {
        tmGrammarRepository.rawRule(forKey: key)
    }

    public func allRepositoryKeys() -> [String] {
        tmGrammarRepository.allRepositoryKeys()
    }

    /// Decode `Data` as a TextMate JSON grammar (e.g. `typescript.json`).
    public static func decode(data: Data) throws -> TMJSONGrammar {
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = obj as? [String: Any],
              let scopeName = dict["scopeName"] as? String else {
            throw NSError(domain: "TMJSONGrammar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing scopeName"])
        }

        var patterns: [IRawRule]?
        if let plist = dict["patterns"] as? [[String: Any]] {
            patterns = try plist.map { try JsonRawRule.decode(from: $0) }
        }

        var injections: [String: IRawRule]?
        if let inj = dict["injections"] as? [String: Any] {
            var map: [String: IRawRule] = [:]
            for (k, v) in inj {
                guard let rd = v as? [String: Any] else { continue }
                map[k] = try JsonRawRule.decode(from: rd)
            }
            injections = map
        }

        let repo: PlainMutableRepository
        if let r = dict["repository"] as? [String: Any] {
            repo = try decodeRepository(r)
        } else {
            repo = PlainMutableRepository()
        }

        let sel = dict["injectionSelector"] as? String

        return TMJSONGrammar(
            scopeName: scopeName,
            patterns: patterns,
            injections: injections,
            injectionSelector: sel,
            repository: repo
        )
    }

    fileprivate func adoptMergedRepository(_ repo: PlainMutableRepository) {
        tmGrammarRepository = repo
    }

    /// Copy JSON repository keys into destination (used when cloning for inclusion).
    fileprivate func copyJsonRepositoryKeys(to dest: PlainMutableRepository) {
        for k in jsonRepository.allRepositoryKeys() where k != "$vscodeTextmateLocation" {
            dest.putRule(jsonRepository.rawRule(forKey: k), forKey: k)
        }
        dest.vscodeTextmateLocation = jsonRepository.vscodeTextmateLocation
    }
}

/// vscode-textmate `initGrammar` — wires `$self` / `$base` into the grammar repository (mutates `grammar`).
public func tmInitGrammar(_ grammar: TMJSONGrammar, base: IRawRule? = nil) -> TMJSONGrammar {
    let merged = PlainMutableRepository()
    grammar.copyJsonRepositoryKeys(to: merged)

    let selfRule = SyntheticBundledRule(host: grammar)

    let baseRule: IRawRule = base ?? selfRule
    merged.putRule(selfRule, forKey: "$self")
    merged.putRule(baseRule, forKey: "$base")

    grammar.adoptMergedRepository(merged)
    return grammar
}

/// `$self` repository synthetic rule: exposes outer grammar patterns + scope name.
private final class SyntheticBundledRule: IRawRule {
    unowned let host: TMJSONGrammar
    var id: RuleId?
    init(host: TMJSONGrammar) { self.host = host }

    var vscodeTextmateLocation: ILocation? { host.vscodeTextmateLocation }
    var include: String? { nil }
    var name: String? { host.scopeName }
    var contentName: String? { nil }
    var match: String? { nil }
    var captures: IRawCaptures? { nil }
    var begin: String? { nil }
    var beginCaptures: IRawCaptures? { nil }
    var end: String? { nil }
    var endCaptures: IRawCaptures? { nil }
    var `while`: String? { nil }
    var whileCaptures: IRawCaptures? { nil }
    var patterns: [IRawRule]? { host.patterns }
    var repository: IRawRepository? { nil }
    var applyEndPatternLast: Bool? { nil }
}
