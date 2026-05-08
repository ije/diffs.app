// TMRegExpSource.swift — vscode-textmate `rule.ts`: RegExpSource, RegExpSourceList, CompiledRule

import Foundation

private let tmBackreferenceRegex = try! NSRegularExpression(pattern: #"\\(\d+)"#, options: [])

/// TS `RegExpSource<TRuleId>` equivalent.
public final class RegExpSourceItem<TRuleId: Hashable & Sendable>: @unchecked Sendable {

    private final class AnchorCache: Sendable {
        let A0_G0: String
        let A0_G1: String
        let A1_G0: String
        let A1_G1: String
        init(_ t: AnchorTuple) {
            A0_G0 = t.A0_G0
            A0_G1 = t.A0_G1
            A1_G0 = t.A1_G0
            A1_G1 = t.A1_G1
        }
    }

    private struct AnchorTuple: Sendable {
        var A0_G0: String
        var A0_G1: String
        var A1_G0: String
        var A1_G1: String
    }

    private static func hasBackreference(_ s: String) -> Bool {
        let ns = s as NSString
        return tmBackreferenceRegex.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) != nil
    }

    public let ruleId: TRuleId
    public private(set) var source: String
    public let hasAnchor: Bool
    public let hasBackReferences: Bool
    private var anchorCache: AnchorCache?

    public init(_ regExpSource: String, ruleId: TRuleId) {
        self.ruleId = ruleId
        if regExpSource.isEmpty {
            hasAnchor = false
            source = regExpSource
        } else {
            var last = regExpSource.startIndex
            var output = ""
            var anchorFlag = false
            var i = regExpSource.startIndex
            while i < regExpSource.endIndex {
                let ch = regExpSource[i]
                if ch == "\\" {
                    let j = regExpSource.index(after: i)
                    if j < regExpSource.endIndex {
                        let nx = regExpSource[j]
                        if nx == "z" {
                            output.append(contentsOf: regExpSource[last..<i])
                            output.append("$(?!\\n)(?<!\\n)")
                            last = regExpSource.index(after: j)
                            i = last
                            continue
                        }
                        if nx == "A" || nx == "G" {
                            anchorFlag = true
                        }
                        i = j
                    }
                }
                i = regExpSource.index(after: i)
            }
            hasAnchor = anchorFlag
            source = last == regExpSource.startIndex
                ? regExpSource
                : output + String(regExpSource[last...])
        }
        hasBackReferences = Self.hasBackreference(source)
        anchorCache = hasAnchor ? AnchorCache(Self.buildAnchors(source)) : nil
    }

    public func clone() -> RegExpSourceItem<TRuleId> {
        RegExpSourceItem(source, ruleId: ruleId)
    }

    public func setSource(_ newSource: String) {
        guard source != newSource else { return }
        source = newSource
        anchorCache = hasAnchor ? AnchorCache(Self.buildAnchors(source)) : nil
    }

    public func resolveBackReferences(lineText: String, captureIndices: [IOnigCaptureIndex]) -> String {
        let line = lineText as NSString
        let captured: [String] = captureIndices.map {
            guard $0.start <= $0.end, $0.start >= 0, $0.end <= line.length else { return "" }
            return line.substring(with: NSRange(location: $0.start, length: $0.end - $0.start))
        }
        let ns = source as NSString
        var result = ""
        var lastUtf16 = 0
        tmBackreferenceRegex.enumerateMatches(in: source, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            if match.range.location > lastUtf16 {
                result.append(ns.substring(with: NSRange(location: lastUtf16, length: match.range.location - lastUtf16)))
            }
            let g1 = ns.substring(with: match.range(at: 1))
            guard let digit = Int(g1) else { return }
            let repl = digit < captured.count ? escapeRegExpCharacters(captured[digit]) : ""
            result.append(repl)
            lastUtf16 = match.range.location + match.range.length
        }
        if lastUtf16 < ns.length {
            result.append(ns.substring(from: lastUtf16))
        }
        return result
    }

    public func resolveAnchors(allowA: Bool, allowG: Bool) -> String {
        guard hasAnchor, let anchorCache else { return source }
        if allowA {
            return allowG ? anchorCache.A1_G1 : anchorCache.A1_G0
        }
        return allowG ? anchorCache.A0_G1 : anchorCache.A0_G0
    }

    private static func buildAnchors(_ src: String) -> AnchorTuple {
        let chars = Array(src)
        let n = chars.count
        var A0_G0 = chars
        var A0_G1 = chars
        var A1_G0 = chars
        var A1_G1 = chars
        var pos = 0
        while pos < n {
            let ch = chars[pos]
            A0_G0[pos] = ch
            A0_G1[pos] = ch
            A1_G0[pos] = ch
            A1_G1[pos] = ch
            if ch == "\\", pos + 1 < n {
                let nextCh = chars[pos + 1]
                switch nextCh {
                case "A":
                    A0_G0[pos + 1] = "\u{FFFF}"
                    A0_G1[pos + 1] = "\u{FFFF}"
                    A1_G0[pos + 1] = "A"
                    A1_G1[pos + 1] = "A"
                case "G":
                    A0_G0[pos + 1] = "\u{FFFF}"
                    A0_G1[pos + 1] = "G"
                    A1_G0[pos + 1] = "\u{FFFF}"
                    A1_G1[pos + 1] = "G"
                default:
                    A0_G0[pos + 1] = nextCh
                    A0_G1[pos + 1] = nextCh
                    A1_G0[pos + 1] = nextCh
                    A1_G1[pos + 1] = nextCh
                }
                pos += 2
                continue
            }
            pos += 1
        }
        return AnchorTuple(
            A0_G0: String(A0_G0),
            A0_G1: String(A0_G1),
            A1_G0: String(A1_G0),
            A1_G1: String(A1_G1))
    }
}

// MARK: - RegExpSourceList

private struct RegExpAnchorsCache<TRuleId: Hashable & Sendable>: Sendable {
    var A0_G0: CompiledRule<TRuleId>?
    var A0_G1: CompiledRule<TRuleId>?
    var A1_G0: CompiledRule<TRuleId>?
    var A1_G1: CompiledRule<TRuleId>?

    init() {
        A0_G0 = nil
        A0_G1 = nil
        A1_G0 = nil
        A1_G1 = nil
    }
}

public final class RegExpSourceList<TRuleId: Hashable & Sendable>: @unchecked Sendable {

    private var items: [RegExpSourceItem<TRuleId>] = []
    private var hasAnchors = false
    private var cached: CompiledRule<TRuleId>?
    private var anchorCache = RegExpAnchorsCache<TRuleId>()

    public init() {}

    public func dispose() {
        disposeCaches()
    }

    private func disposeCaches() {
        cached?.dispose()
        cached = nil
        clearSlot(&anchorCache.A0_G0)
        clearSlot(&anchorCache.A0_G1)
        clearSlot(&anchorCache.A1_G0)
        clearSlot(&anchorCache.A1_G1)
    }

    private func clearSlot(_ slot: inout CompiledRule<TRuleId>?) {
        slot?.dispose()
        slot = nil
    }

    public func push(_ item: RegExpSourceItem<TRuleId>) {
        items.append(item)
        hasAnchors = hasAnchors || item.hasAnchor
    }

    public func unshift(_ item: RegExpSourceItem<TRuleId>) {
        items.insert(item, at: 0)
        hasAnchors = hasAnchors || item.hasAnchor
    }

    public func length() -> Int { items.count }

    public func setSource(index: Int, newSource: String) {
        guard items.indices.contains(index), items[index].source != newSource else { return }
        disposeCaches()
        items[index].setSource(newSource)
    }

    public func compile(onigLib: IOnigLib) throws -> CompiledRule<TRuleId> {
        if cached == nil {
            cached = try CompiledRule(onigLib: onigLib, regExps: items.map(\.source), rules: items.map(\.ruleId))
        }
        return cached!
    }

    public func compileAG(onigLib: IOnigLib, allowA: Bool, allowG: Bool) throws -> CompiledRule<TRuleId> {
        guard hasAnchors else {
            return try compile(onigLib: onigLib)
        }
        switch (allowA, allowG) {
        case (true, true):
            if anchorCache.A1_G1 == nil {
                anchorCache.A1_G1 = try bake(onigLib: onigLib, allowA: true, allowG: true)
            }
            return anchorCache.A1_G1!
        case (true, false):
            if anchorCache.A1_G0 == nil {
                anchorCache.A1_G0 = try bake(onigLib: onigLib, allowA: true, allowG: false)
            }
            return anchorCache.A1_G0!
        case (false, true):
            if anchorCache.A0_G1 == nil {
                anchorCache.A0_G1 = try bake(onigLib: onigLib, allowA: false, allowG: true)
            }
            return anchorCache.A0_G1!
        case (false, false):
            if anchorCache.A0_G0 == nil {
                anchorCache.A0_G0 = try bake(onigLib: onigLib, allowA: false, allowG: false)
            }
            return anchorCache.A0_G0!
        }
    }

    private func bake(onigLib: IOnigLib, allowA: Bool, allowG: Bool) throws -> CompiledRule<TRuleId> {
        try CompiledRule(
            onigLib: onigLib,
            regExps: items.map { $0.resolveAnchors(allowA: allowA, allowG: allowG) },
            rules: items.map(\.ruleId))
    }
}

// MARK: - CompiledRule

public final class CompiledRule<TRuleId: Hashable & Sendable>: @unchecked Sendable {

    private let scanner: OnigScannerProtocol
    private let regExps: [String]
    private let rules: [TRuleId]

    public init(onigLib: IOnigLib, regExps: [String], rules: [TRuleId]) throws {
        scanner = try onigLib.createOnigScanner(regExps)
        self.regExps = regExps
        self.rules = rules
    }

    public func dispose() {
        scanner.dispose()
    }

    public func findNextMatch(
        string line: OnigStringProtocol,
        startPosition: Int,
        options: FindOption = .none
    ) -> IFindNextMatchResult<TRuleId>? {
        guard let m = scanner.findNextMatch(string: line, startPosition: startPosition, options: options) else {
            return nil
        }
        return IFindNextMatchResult(ruleId: rules[m.index], captureIndices: m.captureIndices)
    }

    public func findNextMatch(
        string line: String,
        startPosition: Int,
        options: FindOption = .none
    ) -> IFindNextMatchResult<TRuleId>? {
        guard let m = scanner.findNextMatch(string: line, startPosition: startPosition, options: options) else {
            return nil
        }
        return IFindNextMatchResult(ruleId: rules[m.index], captureIndices: m.captureIndices)
    }
}

extension CompiledRule: CustomStringConvertible {
    public var description: String {
        zip(rules, regExps).map { rid, rex in "   - \(rid): \(rex)" }.joined(separator: "\n")
    }
}
