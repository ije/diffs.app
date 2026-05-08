// vscode-textmate `utils.ts`

import Darwin
import Foundation

private func shallowCloneThing(_ any: Any) -> Any {
    if let arr = any as? [Any] {
        return cloneArray(arr)
    }
    if let dict = any as? [String: Any] {
        var r: [String: Any] = [:]
        for (k, v) in dict {
            r[k] = shallowCloneThing(v)
        }
        return r
    }
    return any
}

private func cloneArray(_ arr: [Any]) -> [Any] {
    arr.map { shallowCloneThing($0) }
}

public func swiftTMClone<Value>(_ something: Value) -> Value {
    shallowCloneThing(something) as! Value
}

public func mergeObjects(_ target: inout [String: Any], sources: [[String: Any]]) {
    for source in sources {
        for (k, v) in source {
            target[k] = v
        }
    }
}

public func mergeDictionaryShallow<Key: Hashable, Value>(_ first: [Key: Value], _ seconds: [[Key: Value]]) -> [Key: Value] {
    var m = first
    for source in seconds {
        for (k, v) in source {
            m[k] = v
        }
    }
    return m
}

/// TS `basename`.
public func textMateBasename(_ path: String) -> String {
    func twiddleLastIndex(of ch: Character, in path: String) -> Int32 {
        guard let swiftIdx = path.lastIndex(of: ch) else { return ~Int32(-1) }
        let dist = Int32(truncatingIfNeeded: path.utf16.distance(from: path.startIndex, to: swiftIdx))
        return ~dist
    }
    let idx: Int32 = {
        let t1 = twiddleLastIndex(of: "/", in: path)
        let t2 = twiddleLastIndex(of: "\\", in: path)
        return t1 != 0 ? t1 : t2
    }()
    if idx == 0 { return path }
    let decoded = ~idx // UTF‑16 column of separator
    let pathLen32 = Int32(truncatingIfNeeded: path.utf16.count)
    if decoded == pathLen32 - 1 {
        return textMateBasename(String(path.dropLast()))
    }
    let substrStart = Int(truncatingIfNeeded: decoded + 1)
    let start = path.utf16.index(path.utf16.startIndex, offsetBy: substrStart)
    return String(path[start...])
}

/// Matches browser `performance.now()` (milliseconds, monotonic on Darwin).
public func performanceNow() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_UPTIME_RAW, &ts)
    return Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1_000_000
}

public func tmStrcmp(_ a: String, _ b: String) -> Int {
    if a < b { return -1 }
    if a > b { return 1 }
    return 0
}

public func tmStrArrCmp(_ a: [String]?, _ b: [String]?) -> Int {
    if a == nil && b == nil { return 0 }
    if a == nil { return -1 }
    if b == nil { return 1 }
    let a1 = a!
    let b1 = b!
    if a1.count == b1.count {
        for i in a1.indices {
            let r = tmStrcmp(a1[i], b1[i])
            if r != 0 { return r }
        }
        return 0
    }
    return a1.count - b1.count
}

private let validHexRE: [NSRegularExpression] = {
    let patterns = ["^#[0-9a-f]{6}$", "^#[0-9a-f]{8}$", "^#[0-9a-f]{3}$", "^#[0-9a-f]{4}$"]
    return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
}()

public func isValidHexColor(_ hex: String) -> Bool {
    let ns = hex as NSString
    let len = ns.length
    for re in validHexRE where re.firstMatch(in: hex, options: [], range: NSRange(location: 0, length: len)) != nil {
        return true
    }
    return false
}

/// Escapes regular-expression metacharacters (same as vscode-textmate `escapeRegExpCharacters`).
public func escapeRegExpCharacters(_ value: String) -> String {
    let specials: Set<Character> = ["\\", "|", "(", "[", "{", "}", "]", ")", ".", "?", "*", "+", "^", "$"]
    return value.reduce(into: "") { out, ch in
        if specials.contains(ch) {
            out.append("\\")
            out.append(ch)
        } else {
            out.append(ch)
        }
    }
}

public final class CachedFnClass<TKey: Hashable, TValue> {
    private var cache: [TKey: TValue] = [:]
    private let fn: (TKey) -> TValue

    public init(_ fn: @escaping (TKey) -> TValue) {
        self.fn = fn
    }

    public func get(_ key: TKey) -> TValue {
        if let v = cache[key] { return v }
        let v = fn(key)
        cache[key] = v
        return v
    }
}

private var rtlRe: NSRegularExpression = {
    let pat = #"(?:[\u05BE\u05C0\u05C3\u05C6\u05D0-\u05F4\u0608\u060B\u060D\u061B-\u064A\u066D-\u066F\u0671-\u06D5\u06E5\u06E6\u06EE\u06EF\u06FA-\u0710\u0712-\u072F\u074D-\u07A5\u07B1-\u07EA\u07F4\u07F5\u07FA\u07FE-\u0815\u081A\u0824\u0828\u0830-\u0858\u085E-\u088E\u08A0-\u08C9\u200F\uFB1D\uFB1F-\uFB28\uFB2A-\uFD3D\uFD50-\uFDC7\uFDF0-\uFDFC\uFE70-\uFEFC]|\uD802[\uDC00-\uDD1B\uDD20-\uDE00\uDE10-\uDE35\uDE40-\uDEE4\uDEEB-\uDF35\uDF40-\uDFFF]|\uD803[\uDC00-\uDD23\uDE80-\uDEA9\uDEAD-\uDF45\uDF51-\uDF81\uDF86-\uDFF6]|\uD83A[\uDC00-\uDCCF\uDD00-\uDD43\uDD4B-\uDFFF]|\uD83B[\uDC00-\uDEBB])"#
    return try! NSRegularExpression(pattern: pat, options: [])
}()

public func containsRTL(_ str: String) -> Bool {
    rtlRe.firstMatch(in: str, options: [], range: NSRange(location: 0, length: (str as NSString).length)) != nil
}

/// Deprecated alias for older call sites — same as `performanceNow()`.
public func tmPerformanceNow() -> Double { performanceNow() }
