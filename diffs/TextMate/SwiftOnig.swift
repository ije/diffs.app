import Foundation

// MARK: - UTF-8 / UTF-16 (vscode-oniguruma UtfString)

struct UtfStringMaps {
    let utf16Length: Int
    let utf8Length: Int
    let utf8Bytes: Data
    let utf16OffsetToUtf8: [UInt32]?
    let utf8OffsetToUtf16: [UInt32]?

    init(_ str: String) {
        let utf16Length = str.utf16.count
        var utf8Value = [UInt8]()
        utf8Value.reserveCapacity(str.utf8.count)
        let computeIndicesMapping = str.utf8.count != str.utf16.count
        var utf16OffsetToUtf8: [UInt32]? = computeIndicesMapping ? [UInt32](repeating: 0, count: utf16Length + 1) : nil
        var utf8OffsetToUtf16: [UInt32]? = computeIndicesMapping ? [UInt32](repeating: 0, count: str.utf8.count + 1) : nil
        if computeIndicesMapping {
            utf16OffsetToUtf8![utf16Length] = UInt32(str.utf8.count)
            utf8OffsetToUtf16![str.utf8.count] = UInt32(utf16Length)
        }

        var i8 = 0
        var i16 = 0
        let ns = str as NSString
        while i16 < utf16Length {
            let charCode = ns.character(at: i16)
            var codePoint = Int(charCode)
            var wasSurrogatePair = false
            if charCode >= 0xd800 && charCode <= 0xdbff && i16 + 1 < utf16Length {
                let nextCharCode = ns.character(at: i16 + 1)
                if nextCharCode >= 0xdc00 && nextCharCode <= 0xdfff {
                    codePoint = (((Int(charCode) - 0xd800) << 10) + 0x10000) | (Int(nextCharCode) - 0xdc00)
                    wasSurrogatePair = true
                }
            }

            if computeIndicesMapping {
                utf16OffsetToUtf8![i16] = UInt32(i8)
                if wasSurrogatePair { utf16OffsetToUtf8![i16 + 1] = UInt32(i8) }
                if codePoint <= 0x7f {
                    utf8OffsetToUtf16![i8] = UInt32(i16)
                } else if codePoint <= 0x7ff {
                    utf8OffsetToUtf16![i8] = UInt32(i16)
                    utf8OffsetToUtf16![i8 + 1] = UInt32(i16)
                } else if codePoint <= 0xffff {
                    utf8OffsetToUtf16![i8] = UInt32(i16)
                    utf8OffsetToUtf16![i8 + 1] = UInt32(i16)
                    utf8OffsetToUtf16![i8 + 2] = UInt32(i16)
                } else {
                    utf8OffsetToUtf16![i8] = UInt32(i16)
                    utf8OffsetToUtf16![i8 + 1] = UInt32(i16)
                    utf8OffsetToUtf16![i8 + 2] = UInt32(i16)
                    utf8OffsetToUtf16![i8 + 3] = UInt32(i16)
                }
            }

            if codePoint <= 0x7f {
                utf8Value.append(UInt8(codePoint))
                i8 += 1
            } else if codePoint <= 0x7ff {
                utf8Value.append(UInt8(0b11000000 | ((codePoint & 0b00000000000000000000011111000000) >> 6)))
                utf8Value.append(UInt8(0b10000000 | ((codePoint & 0b00000000000000000000000000111111))))
                i8 += 2
            } else if codePoint <= 0xffff {
                utf8Value.append(UInt8(0b11100000 | ((codePoint & 0b00000000000000001111000000000000) >> 12)))
                utf8Value.append(UInt8(0b10000000 | ((codePoint & 0b00000000000000000000111111000000) >> 6)))
                utf8Value.append(UInt8(0b10000000 | ((codePoint & 0b00000000000000000000000000111111))))
                i8 += 3
            } else {
                utf8Value.append(UInt8(0b11110000 | ((codePoint & 0b00000000000111000000000000000000) >> 18)))
                utf8Value.append(UInt8(0b10000000 | ((codePoint & 0b00000000000000111111000000000000) >> 12)))
                utf8Value.append(UInt8(0b10000000 | ((codePoint & 0b00000000000000000000111111000000) >> 6)))
                utf8Value.append(UInt8(0b10000000 | ((codePoint & 0b00000000000000000000000000111111))))
                i8 += 4
            }

            i16 += wasSurrogatePair ? 2 : 1
        }

        self.utf16Length = utf16Length
        self.utf8Length = utf8Value.count
        self.utf8Bytes = Data(utf8Value)
        self.utf16OffsetToUtf8 = utf16OffsetToUtf8
        self.utf8OffsetToUtf16 = utf8OffsetToUtf16
    }

    func utf16OffsetToUtf8Offset(_ utf16Offset: Int) -> Int {
        guard let m = utf16OffsetToUtf8 else { return utf16Offset }
        if utf16Offset < 0 { return 0 }
        if utf16Offset > utf16Length { return utf8Length }
        return Int(m[utf16Offset])
    }

    func utf8OffsetToUtf16Offset(_ utf8Offset: Int) -> Int {
        guard let m = utf8OffsetToUtf16 else { return utf8Offset }
        if utf8Offset < 0 { return 0 }
        if utf8Offset > utf8Length { return utf16Length }
        return Int(m[utf8Offset])
    }
}

// MARK: - Onig

struct OnigCaptureIndex: IOnigCaptureIndex {
    let start: Int
    let end: Int
    let length: Int
}

struct OnigMatch {
    let index: Int
    let captureIndices: [OnigCaptureIndex]
}

enum OnigError: Error {
    case scannerCreateFailed
}

private var onigStringId: Int = 0

final class OnigString {
    let content: String
    let maps: UtfStringMaps
    let utf8Bytes: Data
    let cacheId: Int

    init(_ content: String) {
        self.content = content
        self.maps = UtfStringMaps(content)
        self.utf8Bytes = maps.utf8Bytes
        onigStringId &+= 1
        self.cacheId = onigStringId
    }
}

final class OnigScanner {
    /// Opaque C handle (`VSCodeOnigScanner *`) — avoids Swift 6 `void*` / `OpaquePointer` mismatches at call sites.
    private let scanner: OpaquePointer
    private let options: Int32

    init(patterns: [String], options: Int32 = Int32(ONIG_OPTION_CAPTURE_GROUP)) throws {
        self.options = options
        let n = patterns.count
        var tempPtrs: [UnsafeMutablePointer<UInt8>] = []
        var lens: [Int32] = []
        tempPtrs.reserveCapacity(n)
        lens.reserveCapacity(n)
        for p in patterns {
            let u8 = Array(p.utf8)
            let mem = UnsafeMutablePointer<UInt8>.allocate(capacity: u8.count)
            mem.initialize(from: u8, count: u8.count)
            tempPtrs.append(mem)
            lens.append(Int32(u8.count))
        }
        defer {
            for m in tempPtrs { m.deallocate() }
        }
        let created: OpaquePointer? = tempPtrs.withUnsafeBufferPointer { pbuf in
            lens.withUnsafeBufferPointer { lbuf in
                var addrList = [UnsafePointer<UInt8>?]()
                addrList.reserveCapacity(n)
                for i in 0..<n {
                    addrList.append(UnsafePointer(pbuf[i]))
                }
                return addrList.withUnsafeBufferPointer { abuf in
                    vscode_onig_scanner_create(
                        abuf.baseAddress,
                        lbuf.baseAddress,
                        Int32(n),
                        options,
                        nil
                    )
                }
            }
        }
        guard let s = created else { throw OnigError.scannerCreateFailed }
        scanner = s
    }

    deinit {
        vscode_onig_scanner_free(scanner)
    }

    /// `extraSearchOptions` are OR’d with compile-time scanner options (e.g. `ONIG_OPTION_CAPTURE_GROUP`) for `onig_search`.
    func findNextMatch(string: OnigString, startPositionUtf16: Int, extraSearchOptions: Int32 = 0) -> OnigMatch? {
        let posBytes = string.maps.utf16OffsetToUtf8Offset(startPositionUtf16)
        let searchOpts = options | extraSearchOptions
        return string.utf8Bytes.withUnsafeBytes { raw -> OnigMatch? in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            guard let buf = vscode_onig_scanner_find_next_match(
                scanner,
                Int32(string.cacheId),
                base,
                Int32(string.maps.utf8Length),
                Int32(posBytes),
                searchOpts
            ) else { return nil }
            defer { vscode_onig_free_match_result(buf) }
            let idx = Int(buf[0])
            let cnt = Int(buf[1])
            var caps: [OnigCaptureIndex] = []
            caps.reserveCapacity(cnt)
            for i in 0..<cnt {
                let b = Int(buf[2 + 2 * i])
                let e = Int(buf[2 + 2 * i + 1])
                let bs = string.maps.utf8OffsetToUtf16Offset(b)
                let es = string.maps.utf8OffsetToUtf16Offset(e)
                caps.append(OnigCaptureIndex(start: bs, end: es, length: es - bs))
            }
            return OnigMatch(index: idx, captureIndices: caps)
        }
    }
}

final class VSCodeOnigLib: @unchecked Sendable {
    init() {}

    func createOnigScanner(_ sources: [String]) throws -> OnigScanner {
        try OnigScanner(patterns: sources)
    }

    func createOnigString(_ str: String) -> OnigString {
        OnigString(str)
    }
}
