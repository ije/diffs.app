// vscode-textmate `registry.ts` + `main.ts` Registry dependency loader.

import Foundation

public final class SyncRegistry: TMGrammarDependencyRepository, TMGrammarRepositoryPort, TMGrammarThemeProvider {
    private var grammarObjs: [ScopeName: Grammar] = [:]
    private var rawGrammars: [ScopeName: IRawGrammar] = [:]
    private var injectionGrammars: [ScopeName: [ScopeName]] = [:]
    private var theme: Theme
    private let onigLib: IOnigLib

    public init(theme: Theme, onigLib: IOnigLib) {
        self.theme = theme
        self.onigLib = onigLib
    }

    public func dispose() {
        for (_, g) in grammarObjs {
            g.dispose()
        }
        grammarObjs.removeAll()
    }

    public func setTheme(_ theme: Theme) {
        self.theme = theme
    }

    public func getColorMap() -> [String] {
        theme.getColorMap()
    }

    public func addGrammar(_ grammar: IRawGrammar, injectionScopeNames: [ScopeName]? = nil) {
        rawGrammars[grammar.scopeName] = grammar
        if let injectionScopeNames {
            injectionGrammars[grammar.scopeName] = injectionScopeNames
        }
    }

    public func lookup(scopeName: ScopeName) -> IRawGrammar? {
        rawGrammars[scopeName]
    }

    public func injections(forScope scopeName: ScopeName) -> [ScopeName]? {
        injectionGrammars[scopeName]
    }

    public func lookupGrammar(scopeName: String) -> IRawGrammar? {
        lookup(scopeName: scopeName)
    }

    public func injectionScopeNames(for targetScope: String) -> [String]? {
        injections(forScope: targetScope)
    }

    public func getDefaults() -> StyleAttributes {
        theme.getDefaults()
    }

    public func themeMatch(scopePath: ScopeStack?) -> StyleAttributes? {
        theme.themeMatch(scopePath: scopePath)
    }

    public func grammarForScopeName(
        scopeName: ScopeName,
        initialLanguage: UInt32,
        embeddedLanguages: TMEmbeddedLanguagesMap?,
        tokenTypes: TMTokenTypeMap?,
        balancedBracketSelectors: BalancedBracketSelectors?
    ) throws -> Grammar? {
        if let existing = grammarObjs[scopeName] {
            return existing
        }
        guard let rawGrammar = rawGrammars[scopeName] else {
            return nil
        }
        let built = tmCreateGrammar(
            scopeName: scopeName,
            grammar: rawGrammar,
            initialLanguage: initialLanguage,
            embeddedLanguages: embeddedLanguages,
            tokenTypes: tokenTypes,
            balancedBracketSelectors: balancedBracketSelectors,
            grammarRepository: self,
            onigLib: onigLib
        )
        grammarObjs[scopeName] = built
        return built
    }

    public func ensureGrammar(scopeName: ScopeName, load: (ScopeName) throws -> IRawGrammar?) throws {
        if rawGrammars[scopeName] != nil { return }
        guard let g = try load(scopeName) else { return }
        addGrammar(g)
    }
}

public final class TMRegistry {
    public struct Options {
        public var themeRaw: IRawTheme?
        public var colorMap: [String]?
        public var loadGrammar: (ScopeName) throws -> IRawGrammar?

        public init(themeRaw: IRawTheme?, colorMap: [String]?, loadGrammar: @escaping (ScopeName) throws -> IRawGrammar?) {
            self.themeRaw = themeRaw
            self.colorMap = colorMap
            self.loadGrammar = loadGrammar
        }
    }

    private let options: Options
    public let syncRegistry: SyncRegistry

    public init(options: Options, onigLib: IOnigLib) {
        self.options = options
        let theme = Theme.createFromRawTheme(source: options.themeRaw, colorMap: options.colorMap)
        syncRegistry = SyncRegistry(theme: theme, onigLib: onigLib)
    }

    public func dispose() {
        syncRegistry.dispose()
    }

    /// Loads dependency closures (`ScopeDependencyProcessor`) then builds compiled grammar for `initialScopeName`.
    public func loadGrammar(initialScopeName: ScopeName) throws -> Grammar? {
        let processor = ScopeDependencyProcessor(repo: syncRegistry, initialScopeName: initialScopeName)
        while !processor.queued.isEmpty {
            let batch = processor.queued
            for ref in batch {
                let scopeName: ScopeName = {
                    if let top = ref as? TopLevelRuleReference {
                        return top.scopeName
                    }
                    if let sub = ref as? TopLevelRepositoryRuleReference {
                        return sub.scopeName
                    }
                    return initialScopeName
                }()
                try syncRegistry.ensureGrammar(scopeName: scopeName, load: options.loadGrammar)
            }
            processor.processQueue()
        }

        return try syncRegistry.grammarForScopeName(
            scopeName: initialScopeName,
            initialLanguage: 1,
            embeddedLanguages: nil,
            tokenTypes: nil,
            balancedBracketSelectors: nil
        )
    }

    /// Pre-register grammar JSON without asynchronous loader wiring (demo helper).
    public func registerDecodedGrammar(_ grammar: IRawGrammar) {
        syncRegistry.addGrammar(grammar)
    }

    public func grammar(forScope scopeName: ScopeName) throws -> Grammar? {
        try syncRegistry.grammarForScopeName(
            scopeName: scopeName,
            initialLanguage: 1,
            embeddedLanguages: nil,
            tokenTypes: nil,
            balancedBracketSelectors: nil
        )
    }
}
