import Foundation

public func scopesAreMatchingTm(_ scopeName: String, _ fragment: String) -> Bool {
    if scopeName.isEmpty { return false }
    if scopeName == fragment { return true }
    guard scopeName.count > fragment.count else { return false }
    let idx = scopeName.index(scopeName.startIndex, offsetBy: fragment.count)
    guard String(scopeName[..<idx]) == fragment else { return false }
    return scopeName[idx] == "."
}

public func tmNameMatcher(identifiers: [String], scopes: [String]) -> Bool {
    if scopes.count < identifiers.count { return false }
    var last = scopes.startIndex
    for ident in identifiers {
        guard let found = scopes[last...].firstIndex(where: { scopesAreMatchingTm($0, ident) }) else {
            return false
        }
        last = scopes.index(after: found)
    }
    return true
}

private let selectorRegexp = try! NSRegularExpression(pattern: #"([LR]:|[\w\.:][\w\.:\-]*|[\,\|\-\(\)])"#)

private func tokenList(from selector: String) -> [String] {
    let ns = selector as NSString
    var tokens: [String] = []
    var pos = 0
    while pos < ns.length {
        guard let hit = selectorRegexp.firstMatch(in: String(ns),
                                                   options: [],
                                                   range: NSRange(location: pos, length: ns.length &- pos)),
              hit.numberOfRanges > 1,
              hit.range(at: 1).location != NSNotFound else {
            break
        }
        tokens.append(ns.substring(with: hit.range(at: 1)))
        pos = hit.range.location + hit.range.length
    }
    return tokens
}

private func isGlobIdentifierTok(_ tok: String) -> Bool {
    guard let scalar = tok.unicodeScalars.first else { return false }
    return CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:+")).contains(scalar)
}

private enum MatcherEngine {
    typealias Matcher = @Sendable ([String]) -> Bool

    final class Cursor {
        var tokens: [String]
        var i = 0
        init(tokens: [String]) { self.tokens = tokens }

        func peek() -> String? {
            guard i < tokens.count else { return nil }
            return tokens[i]
        }

        func bump() {
            if i < tokens.count { i += 1 }
        }
    }

    static func parseOperand(_ holder: Cursor, matchesName: @escaping ([String], [String]) -> Bool) -> Matcher? {
        guard let tok = holder.peek() else { return nil }

        if tok == "-" {
            holder.bump()
            guard let inner = parseOperand(holder, matchesName: matchesName) else { return nil }
            return { !inner($0) }
        }

        if tok == "(" {
            holder.bump()
            let innerExpr = parseInner(holder, matchesName: matchesName)
            if holder.peek() == ")" { holder.bump() }
            return innerExpr
        }

        if isGlobIdentifierTok(tok) {
            var ids: [String] = []
            while let peeked = holder.peek(), isGlobIdentifierTok(peeked) {
                ids.append(peeked)
                holder.bump()
            }
            return { matchesName(ids, $0) }
        }

        return nil
    }

    static func parseConjunction(_ holder: Cursor, matchesName: @escaping ([String], [String]) -> Bool) -> Matcher {
        var parts: [Matcher] = []
        while let operand = parseOperand(holder, matchesName: matchesName) {
            parts.append(operand)
        }
        if parts.isEmpty { return { _ in true } }
        let boxed = parts
        return { val in boxed.allSatisfy { $0(val) } }
    }

    static func parseInner(_ holder: Cursor, matchesName: @escaping ([String], [String]) -> Bool) -> Matcher {
        var clauses: [Matcher] = []
        clauses.append(parseConjunction(holder, matchesName: matchesName))
        while holder.peek() == "|" || holder.peek() == "," {
            while holder.peek() == "|" || holder.peek() == "," {
                holder.bump()
            }
            clauses.append(parseConjunction(holder, matchesName: matchesName))
        }
        let boxed = clauses
        return { val in boxed.contains { $0(val) } }
    }
}

public func createTmSelectors(_ selector: String, matchesName: @escaping ([String], [String]) -> Bool)
    -> [(matcher: (@Sendable ([String]) -> Bool), priority: Int)]
{
    let allTokens = tokenList(from: selector)
    var collector: [(matcher: (@Sendable ([String]) -> Bool), priority: Int)] = []
    let cursor = MatcherEngine.Cursor(tokens: allTokens)

    while cursor.peek() != nil {
        var priority = 0
        if let prior = cursor.peek(), prior.count == 2, let ch = prior.first, prior.last == ":" {
            switch Character(String(ch)) {
            case "R": priority = 1
            case "L": priority = -1
            default:
                print("TMMatcher: ignoring unknown priority directive \(prior)")
            }
            cursor.bump()
        }

        let matcher = MatcherEngine.parseConjunction(cursor, matchesName: matchesName)
        collector.append((matcher: matcher, priority: priority))

        guard cursor.peek() == "," else { break }
        cursor.bump()
    }

    return collector
}
