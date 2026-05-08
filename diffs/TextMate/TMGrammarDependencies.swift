// vscode-textmate `grammar/grammarDependencies.ts`

import Foundation

/// TS `AbsoluteRuleReference`
public protocol AbsoluteGrammarRuleReference {
    func referenceKey() -> String
}

public struct TopLevelRuleReference: AbsoluteGrammarRuleReference, Sendable {
    public let scopeName: String

    public init(scopeName: String) {
        self.scopeName = scopeName
    }

    public func referenceKey() -> String { scopeName }
}

public struct TopLevelRepositoryRuleReference: AbsoluteGrammarRuleReference, Sendable {
    public let scopeName: String
    public let ruleName: String

    public init(scopeName: String, ruleName: String) {
        self.scopeName = scopeName
        self.ruleName = ruleName
    }

    public func referenceKey() -> String { "\(scopeName)#\(ruleName)" }
}

public final class ExternalReferenceCollector {
    private var references: [any AbsoluteGrammarRuleReference] = []
    private var seenReferenceKeys = Set<String>()
    private(set) var visitedRules = Set<ObjectIdentifier>()

    func markVisited(_ oid: ObjectIdentifier) -> Bool {
        if visitedRules.contains(oid) { return false }
        visitedRules.insert(oid)
        return true
    }
    init() {}

    public var referenced: [any AbsoluteGrammarRuleReference] {
        references
    }

    public func add<R: AbsoluteGrammarRuleReference>(_ reference: R) {
        let key = reference.referenceKey()
        if seenReferenceKeys.contains(key) { return }
        seenReferenceKeys.insert(key)
        references.append(reference)
    }
}

public protocol TMGrammarDependencyRepository {
    func lookupGrammar(scopeName: String) -> IRawGrammar?
    func injectionScopeNames(for targetScope: String) -> [String]?
}

public final class ScopeDependencyProcessor {
    private let repo: TMGrammarDependencyRepository
    private let initialScopeName: String

    public private(set) var seenFullScopeRequests = Set<String>()
    public private(set) var seenPartialScopeRequests = Set<String>()
    public var queued: [any AbsoluteGrammarRuleReference] = []

    public init(repo: TMGrammarDependencyRepository, initialScopeName: String) {
        self.repo = repo
        self.initialScopeName = initialScopeName
        seenFullScopeRequests.insert(initialScopeName)
        queued = [TopLevelRuleReference(scopeName: initialScopeName)]
    }

    public func processQueue() {
        let q = queued
        queued.removeAll()

        let deps = ExternalReferenceCollector()

        for dep in q {
            if let top = dep as? TopLevelRuleReference {
                collectReferencesOf(reference: top, baseGrammarScopeName: initialScopeName, repo: repo, result: deps)
            } else if let sub = dep as? TopLevelRepositoryRuleReference {
                collectReferencesOf(reference: sub, baseGrammarScopeName: initialScopeName, repo: repo, result: deps)
            }
        }

        for dep in deps.referenced {
            if let top = dep as? TopLevelRuleReference {
                if seenFullScopeRequests.contains(top.scopeName) { continue }
                seenFullScopeRequests.insert(top.scopeName)
                queued.append(top)
            } else if let sub = dep as? TopLevelRepositoryRuleReference {
                if seenFullScopeRequests.contains(sub.scopeName) { continue }
                if seenPartialScopeRequests.contains(sub.referenceKey()) { continue }
                seenPartialScopeRequests.insert(sub.referenceKey())
                queued.append(sub)
            }
        }
    }
}

private func collectReferencesOf(
    reference: TopLevelRuleReference,
    baseGrammarScopeName: String,
    repo: TMGrammarDependencyRepository,
    result: ExternalReferenceCollector
) {
    guard let selfGrammar = repo.lookupGrammar(scopeName: reference.scopeName) else {
        if reference.scopeName == baseGrammarScopeName {
            fatalError("No grammar provided for <\(baseGrammarScopeName)>")
        }
        return
    }
    guard let baseGrammar = repo.lookupGrammar(scopeName: baseGrammarScopeName) else { return }

    collectExternalReferencesInTopLevelRule(
        baseGrammar: baseGrammar,
        selfGrammar: selfGrammar,
        result: result
    )

    if let injections = repo.injectionScopeNames(for: reference.scopeName) {
        for inj in injections {
            result.add(TopLevelRuleReference(scopeName: inj))
        }
    }
}

private func collectReferencesOf(
    reference: TopLevelRepositoryRuleReference,
    baseGrammarScopeName: String,
    repo: TMGrammarDependencyRepository,
    result: ExternalReferenceCollector
) {
    guard let selfGrammar = repo.lookupGrammar(scopeName: reference.scopeName) else {
        if reference.scopeName == baseGrammarScopeName {
            fatalError("No grammar provided for <\(baseGrammarScopeName)>")
        }
        return
    }
    guard let baseGrammar = repo.lookupGrammar(scopeName: baseGrammarScopeName) else { return }

    collectExternalReferencesInTopLevelRepositoryRule(
        ruleName: reference.ruleName,
        baseGrammar: baseGrammar,
        selfGrammar: selfGrammar,
        repository: selfGrammar.tmGrammarRepository,
        result: result
    )

    if let injections = repo.injectionScopeNames(for: reference.scopeName) {
        for inj in injections {
            result.add(TopLevelRuleReference(scopeName: inj))
        }
    }
}

private func collectExternalReferencesInTopLevelRepositoryRule(
    ruleName: String,
    baseGrammar: IRawGrammar,
    selfGrammar: IRawGrammar,
    repository: IRawRepository?,
    result: ExternalReferenceCollector
) {
    guard let repository else { return }
    guard let rule = repository.rawRule(forKey: ruleName) else { return }
    collectExternalReferencesInRules(
        rules: [rule],
        baseGrammar: baseGrammar,
        selfGrammar: selfGrammar,
        repository: repository,
        visited: result,
        result: result
    )
}

private func collectExternalReferencesInTopLevelRule(baseGrammar: IRawGrammar, selfGrammar: IRawGrammar, result: ExternalReferenceCollector) {
    if let patterns = selfGrammar.patterns {
        collectExternalReferencesInRules(
            rules: patterns,
            baseGrammar: baseGrammar,
            selfGrammar: selfGrammar,
            repository: selfGrammar.tmGrammarRepository,
            visited: result,
            result: result
        )
    }
    if let injections = selfGrammar.grammarInjections?.values.map({ $0 as IRawRule }) {
        collectExternalReferencesInRules(
            rules: Array(injections),
            baseGrammar: baseGrammar,
            selfGrammar: selfGrammar,
            repository: selfGrammar.tmGrammarRepository,
            visited: result,
            result: result
        )
    }
}

private func collectExternalReferencesInRules(
    rules: [IRawRule],
    baseGrammar: IRawGrammar,
    selfGrammar: IRawGrammar,
    repository: IRawRepository?,
    visited: ExternalReferenceCollector,
    result: ExternalReferenceCollector
) {
    for rule in rules {
        let oid = ObjectIdentifier(rule as AnyObject)
        if !visited.markVisited(oid) { continue }

        let patternRepository: IRawRepository? = {
            guard let repository else { return rule.repository }
            guard let nested = rule.repository else { return repository }
            return mergedRepositoryShallow(base: repository, overlay: nested)
        }()

        if let patterns = rule.patterns {
            collectExternalReferencesInRules(
                rules: patterns,
                baseGrammar: baseGrammar,
                selfGrammar: selfGrammar,
                repository: patternRepository,
                visited: visited,
                result: result
            )
        }

        guard let include = rule.include else { continue }
        let reference = parseInclude(include)

        switch reference {
        case .base:
            collectExternalReferencesInTopLevelRule(
                baseGrammar: baseGrammar,
                selfGrammar: baseGrammar,
                result: result
            )
        case .`self`:
            collectExternalReferencesInTopLevelRule(
                baseGrammar: baseGrammar,
                selfGrammar: selfGrammar,
                result: result
            )
        case .relativeReference(let ruleName):
            collectExternalReferencesInTopLevelRepositoryRule(
                ruleName: ruleName,
                baseGrammar: baseGrammar,
                selfGrammar: selfGrammar,
                repository: patternRepository,
                result: result
            )
        case .topLevelReference(let scopeName):
            handleTopLevelLike(
                scopeName: scopeName,
                ruleName: nil,
                baseGrammar: baseGrammar,
                selfGrammar: selfGrammar,
                patternRepository: patternRepository,
                result: result
            )
        case .topLevelRepositoryReference(let scopeName, let ruleName):
            handleTopLevelLike(
                scopeName: scopeName,
                ruleName: ruleName,
                baseGrammar: baseGrammar,
                selfGrammar: selfGrammar,
                patternRepository: patternRepository,
                result: result
            )
        }
    }
}

private func handleTopLevelLike(
    scopeName: String,
    ruleName: String?,
    baseGrammar: IRawGrammar,
    selfGrammar: IRawGrammar,
    patternRepository: IRawRepository?,
    result: ExternalReferenceCollector
) {
    let selfGrammarOpt: IRawGrammar? =
        scopeName == selfGrammar.scopeName ? selfGrammar
        : scopeName == baseGrammar.scopeName ? baseGrammar
        : nil

    if let selfGrammarOpt {
        let ctx = MergedRuleContext(
            baseGrammar: baseGrammar,
            selfGrammar: selfGrammarOpt,
            repository: patternRepository
        )
        if let ruleName {
            collectExternalReferencesInTopLevelRepositoryRule(
                ruleName: ruleName,
                baseGrammar: ctx.baseGrammar,
                selfGrammar: ctx.selfGrammar,
                repository: ctx.repository,
                result: result
            )
        } else {
            collectExternalReferencesInTopLevelRule(
                baseGrammar: ctx.baseGrammar,
                selfGrammar: ctx.selfGrammar,
                result: result
            )
        }
    } else {
        if let ruleName {
            result.add(TopLevelRepositoryRuleReference(scopeName: scopeName, ruleName: ruleName))
        } else {
            result.add(TopLevelRuleReference(scopeName: scopeName))
        }
    }
}

private struct MergedRuleContext {
    let baseGrammar: IRawGrammar
    let selfGrammar: IRawGrammar
    let repository: IRawRepository?
}

private func mergedRepositoryShallow(base: IRawRepository, overlay: IRawRepository) -> IRawRepository {
    let p = PlainMutableRepository()
    for k in base.allRepositoryKeys() where k != "$vscodeTextmateLocation" {
        p.putRule(base.rawRule(forKey: k), forKey: k)
    }
    for k in overlay.allRepositoryKeys() where k != "$vscodeTextmateLocation" {
        p.putRule(overlay.rawRule(forKey: k), forKey: k)
    }
    p.vscodeTextmateLocation = overlay.vscodeTextmateLocation ?? base.vscodeTextmateLocation
    return p
}

// MARK: - parseInclude (rule.ts overlap)

public enum IncludeReferenceKind: Int, Sendable {
    case base
    case `self`
    case relativeReference
    case topLevelReference
    case topLevelRepositoryReference
}

public enum IncludeReference: Sendable {
    case base
    case `self`
    case relativeReference(ruleName: String)
    case topLevelReference(scopeName: String)
    case topLevelRepositoryReference(scopeName: String, ruleName: String)

    public var kind: IncludeReferenceKind {
        switch self {
        case .base: return .base
        case .`self`: return .`self`
        case .relativeReference: return .relativeReference
        case .topLevelReference: return .topLevelReference
        case .topLevelRepositoryReference: return .topLevelRepositoryReference
        }
    }
}

public func parseInclude(_ include: String) -> IncludeReference {
    if include == "$base" { return .base }
    if include == "$self" { return .`self` }
    if let sharp = include.firstIndex(of: "#") {
        if sharp == include.startIndex {
            let after = include.index(after: sharp)
            return .relativeReference(ruleName: String(include[after...]))
        }
        let scopeName = String(include[..<sharp])
        let ruleStart = include.index(after: sharp)
        let ruleName = String(include[ruleStart...])
        return .topLevelRepositoryReference(scopeName: scopeName, ruleName: ruleName)
    }
    return .topLevelReference(scopeName: include)
}

