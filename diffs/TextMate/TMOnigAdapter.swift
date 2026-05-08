// Bridges native `VSCodeOnigLib` / `OnigScanner` to `IOnigLib` / `OnigScannerProtocol`, mapping
// vscode-textmate `FindOption` search flags to Oniguruma `ONIG_OPTION_*` values (same mapping as vscode-oniguruma).

import Foundation

/// Maps `FindOption` bitmask (1 / 2 / 4 / 8) to Oniguruma search-time options OR’d into `vscode_onig_scanner_find_next_match`.
public func tmOnigSearchOptionsMask(from options: FindOption) -> Int32 {
    var mask: UInt32 = 0
    if options.contains(.notBeginString) { mask |= ONIG_OPTION_NOT_BEGIN_STRING }
    if options.contains(.notEndString) { mask |= ONIG_OPTION_NOT_END_STRING }
    if options.contains(.notBeginPosition) { mask |= ONIG_OPTION_NOT_BEGIN_POSITION }
    _ = options.contains(.debugCall) // parity with wasm layer (no extra search flag)
    return Int32(bitPattern: mask)
}

private final class AdapterOnigString: OnigStringProtocol {
    let backing: OnigString
    init(_ backing: OnigString) { self.backing = backing }
    var content: String { backing.content }
    func dispose() {}
}

private final class AdapterOnigScanner: OnigScannerProtocol {
    private var inner: OnigScanner?

    init(_ inner: OnigScanner) {
        self.inner = inner
    }

    func findNextMatch(string: OnigStringProtocol, startPosition: Int, options: FindOption) -> IOnigMatch? {
        guard let inner else { return nil }
        guard let adapter = string as? AdapterOnigString else {
            return findNextMatch(string: string.content, startPosition: startPosition, options: options)
        }
        let extra = tmOnigSearchOptionsMask(from: options)
        guard let m = inner.findNextMatch(string: adapter.backing, startPositionUtf16: startPosition, extraSearchOptions: extra) else {
            return nil
        }
        let caps: [IOnigCaptureIndex] = m.captureIndices.map { $0 as IOnigCaptureIndex }
        return OnigMatchAdapter(index: m.index, captureIndices: caps)
    }

    func findNextMatch(string: String, startPosition: Int, options: FindOption) -> IOnigMatch? {
        let o = OnigString(string)
        return findNextMatch(string: AdapterOnigString(o), startPosition: startPosition, options: options)
    }

    func dispose() {
        inner = nil
    }
}

private struct OnigMatchAdapter: IOnigMatch {
    let index: Int
    let captureIndices: [IOnigCaptureIndex]
}

/// Drop-in `IOnigLib` for TextMate using the native Oniguruma bridge (`SwiftOnig`).
public final class TMOnigAdapter: IOnigLib {
    private let lib = VSCodeOnigLib()

    public init() {}

    public func createOnigScanner(_ sources: [String]) throws -> OnigScannerProtocol {
        try AdapterOnigScanner(lib.createOnigScanner(sources))
    }

    public func createOnigString(_ str: String) -> OnigStringProtocol {
        AdapterOnigString(lib.createOnigString(str))
    }
}
