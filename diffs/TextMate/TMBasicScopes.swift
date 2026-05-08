// vscode-textmate `grammar/basicScopesAttributeProvider.ts`

import Foundation

public struct BasicScopeAttributes: Sendable {
    public let languageId: UInt32
    public let tokenType: OptionalStandardTokenType

    public init(languageId: UInt32, tokenType: OptionalStandardTokenType) {
        self.languageId = languageId
        self.tokenType = tokenType
    }
}

public typealias TMEmbeddedLanguagesMap = [String: UInt32]

public final class BasicScopeAttributesProvider {
    private let defaultAttributes: BasicScopeAttributes
    private let embeddedLanguagesMatcher: ScopeMatcher<UInt32>

    private static let nullScopeMetadata = BasicScopeAttributes(languageId: 0, tokenType: .notSet)

    private let scopeAttrsLock = NSLock()
    private nonisolated(unsafe) var scopeAttrsCache: [String: BasicScopeAttributes] = [:]

    public init(initialLanguageId: UInt32, embeddedLanguages: TMEmbeddedLanguagesMap?) {
        defaultAttributes = BasicScopeAttributes(languageId: initialLanguageId, tokenType: .notSet)
        let pairs: [(ScopeName, UInt32)] = embeddedLanguages?.map { ($0.key, $0.value) } ?? []
        embeddedLanguagesMatcher = ScopeMatcher(entries: pairs)
    }

    public func getDefaultAttributes() -> BasicScopeAttributes {
        defaultAttributes
    }

    public func getBasicScopeAttributes(scopeName: ScopeName?) -> BasicScopeAttributes {
        guard let scopeName else { return Self.nullScopeMetadata }
        scopeAttrsLock.lock()
        defer { scopeAttrsLock.unlock() }
        if let hit = scopeAttrsCache[scopeName] { return hit }
        let languageId = embeddedLanguagesMatcher.match(scope: scopeName) ?? 0
        let tok = Self.standardTokenType(scopeName)
        let v = BasicScopeAttributes(languageId: languageId, tokenType: tok)
        scopeAttrsCache[scopeName] = v
        return v
    }

    private static let standardTokenTypeRegexp = try! NSRegularExpression(
        pattern: #"\b(comment|string|regex|meta\.embedded)\b"#,
        options: []
    )

    private static func standardTokenType(_ scopeName: String) -> OptionalStandardTokenType {
        let range = NSRange(location: 0, length: (scopeName as NSString).length)
        guard let m = standardTokenTypeRegexp.firstMatch(in: scopeName, options: [], range: range),
              m.numberOfRanges > 1,
              m.range(at: 1).location != NSNotFound else {
            return .notSet
        }
        let ns = scopeName as NSString
        let g1 = ns.substring(with: m.range(at: 1))
        switch g1 {
        case "comment": return .comment
        case "string": return .string
        case "regex": return .regEx
        case "meta.embedded": return .other
        default:
            return .notSet
        }
    }
}

private final class ScopeMatcher<T> where T: Hashable & Sendable {
    private let values: [String: T]?
    private let scopesRegexp: NSRegularExpression?

    init(entries: [(ScopeName, T)]) {
        if entries.isEmpty {
            values = nil
            scopesRegexp = nil
        } else {
            var map: [String: T] = [:]
            for (k, v) in entries { map[k] = v }
            values = map
            let escaped = entries.map { escapeRegExpCharacters($0.0) }.sorted { $0.count > $1.count }
            let inner = escaped.joined(separator: ")|(")
            let pat = #"^(("# + inner + #"))($|\.)"#
            scopesRegexp = try? NSRegularExpression(pattern: pat, options: [])
        }
    }

    func match(scope: ScopeName) -> T? {
        guard let values, let scopesRegexp else { return nil }
        let range = NSRange(location: 0, length: (scope as NSString).length)
        guard let m = scopesRegexp.firstMatch(in: scope, options: [], range: range),
              m.numberOfRanges > 1,
              m.range(at: 1).location != NSNotFound else {
            return nil
        }
        let key = (scope as NSString).substring(with: m.range(at: 1))
        return values[key]
    }
}
