//
//  ContentView.swift
//  diffs
//

import AppKit
import SwiftUI

private extension Color {
    init?(tmHex: String) {
        var hex = tmHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&value) else { return nil }
        let hasAlpha = hex.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xff) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xff) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xff) / 255
        let a = hasAlpha ? Double(value & 0xff) / 255 : 1
        self = Color(red: r, green: g, blue: b, opacity: a)
    }

    init(tmRGBA: TMRGBA) {
        self = Color(red: tmRGBA.r, green: tmRGBA.g, blue: tmRGBA.b, opacity: tmRGBA.a)
    }
}

struct TMRGBA {
    let r: Double
    let g: Double
    let b: Double
    let a: Double

    init?(tmHex: String) {
        var hex = tmHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&value) else { return nil }
        let hasAlpha = hex.count == 8
        r = Double((value >> (hasAlpha ? 24 : 16)) & 0xff) / 255
        g = Double((value >> (hasAlpha ? 16 : 8)) & 0xff) / 255
        b = Double((value >> (hasAlpha ? 8 : 0)) & 0xff) / 255
        a = hasAlpha ? Double(value & 0xff) / 255 : 1
    }

    func composited(on background: TMRGBA) -> TMRGBA {
        let outA = a + background.a * (1 - a)
        guard outA > 0 else { return TMRGBA(r: 0, g: 0, b: 0, a: 0) }
        let outR = ((r * a) + (background.r * background.a * (1 - a))) / outA
        let outG = ((g * a) + (background.g * background.a * (1 - a))) / outA
        let outB = ((b * a) + (background.b * background.a * (1 - a))) / outA
        return TMRGBA(r: outR, g: outG, b: outB, a: outA)
    }

    func contrastDistance(from other: TMRGBA) -> Double {
        abs(r - other.r) + abs(g - other.g) + abs(b - other.b)
    }

    private init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}

private func tmResolvedForeground(
    fgId: Int,
    colorPalette: [String],
    defaultForeground: TMRGBA,
    editorBackground: TMRGBA
) -> Color {
    guard fgId > 0, fgId < colorPalette.count, let candidate = TMRGBA(tmHex: colorPalette[fgId]) else {
        return Color(tmRGBA: defaultForeground)
    }

    let visible = candidate.composited(on: editorBackground)
    if visible.contrastDistance(from: editorBackground) < 0.55 {
        return Color(tmRGBA: defaultForeground)
    }
    return Color(tmRGBA: visible)
}

private func tmPieces(
    forLine sampleLine: String,
    tokens: [UInt32],
    colorPalette: [String],
    defaultForeground: TMRGBA,
    editorBackground: TMRGBA
) -> [(String, Color)] {
    guard tokens.count >= 2 else {
        return [(sampleLine, Color(tmRGBA: defaultForeground))]
    }
    var out: [(String, Color)] = []
    var idx = 0
    while idx + 1 < tokens.count {
        let start = Int(tokens[idx])
        let meta = tokens[idx + 1]
        let fgId = Int(EncodedTokenAttributes.getForeground(meta))
        let end = idx + 2 < tokens.count ? Int(tokens[idx + 2]) : sampleLine.utf16.count
        let lo = max(0, min(start, sampleLine.utf16.count))
        let hi = max(lo, min(end, sampleLine.utf16.count))
        let seg = (sampleLine as NSString).substring(with: NSRange(location: lo, length: hi &- lo))
        let color = tmResolvedForeground(
            fgId: fgId,
            colorPalette: colorPalette,
            defaultForeground: defaultForeground,
            editorBackground: editorBackground
        )
        out.append((seg, color))
        idx += 2
    }
    return out
}

private func tmAttributedLine(
    sampleLine: String,
    tokens: [UInt32],
    colorPalette: [String],
    defaultForeground: TMRGBA,
    editorBackground: TMRGBA,
    font: NSFont,
    highlightedRanges: [NSRange] = []
) -> NSAttributedString {
    let attributed = NSMutableAttributedString()
    var utf16Offset = 0
    for piece in tmPieces(
        forLine: sampleLine,
        tokens: tokens,
        colorPalette: colorPalette,
        defaultForeground: defaultForeground,
        editorBackground: editorBackground
    ) {
        let pieceLength = piece.0.utf16.count
        let pieceRange = NSRange(location: utf16Offset, length: pieceLength)
        let backgroundColor = highlightedRanges.contains { NSIntersectionRange($0, pieceRange).length > 0 }
            ? NSColor(Color.white.opacity(0.7))
            : .clear
        attributed.append(NSAttributedString(
            string: piece.0,
            attributes: [
                .font: font,
                .foregroundColor: NSColor(piece.1),
                .backgroundColor: backgroundColor
            ]
        ))
        utf16Offset += pieceLength
    }
    return attributed
}

struct DiffCodeLine {
    let number: Int
    let text: String
    let tokens: [UInt32]
    let backgroundColor: Color?
    let accentColor: Color?
    let emphasizedRanges: [NSRange]
}

struct SelectableCodeTextView: NSViewRepresentable {
    let lineHeight: CGFloat = 24
    let lineNumberSpacing: CGFloat = 8
    let highlightedLines: [DiffCodeLine]
    let colorPalette: [String]
    let defaultForeground: TMRGBA
    let editorBackground: TMRGBA
    let lineNumberColor: Color
    let lineNumberTint: Color?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = ""

        let lineNumberView = NSTextView()
        lineNumberView.isEditable = false
        lineNumberView.isSelectable = false
        lineNumberView.drawsBackground = false
        lineNumberView.backgroundColor = .clear
        lineNumberView.textContainer?.lineFragmentPadding = 0
        lineNumberView.isHorizontallyResizable = false
        lineNumberView.isVerticallyResizable = true
        lineNumberView.textContainer?.widthTracksTextView = true
        lineNumberView.textContainer?.containerSize = NSSize(width: 32, height: CGFloat.greatestFiniteMagnitude)

        let lineNumberScrollView = NSScrollView()
        lineNumberScrollView.borderType = .noBorder
        lineNumberScrollView.hasVerticalScroller = false
        lineNumberScrollView.hasHorizontalScroller = false
        lineNumberScrollView.drawsBackground = false
        lineNumberScrollView.documentView = lineNumberView
        lineNumberScrollView.translatesAutoresizingMaskIntoConstraints = false
        lineNumberScrollView.contentView.postsBoundsChangedNotifications = true

        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(lineNumberScrollView)
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            lineNumberScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            lineNumberScrollView.topAnchor.constraint(equalTo: container.topAnchor),
            lineNumberScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: lineNumberScrollView.trailingAnchor, constant: lineNumberSpacing),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        let lineNumberWidthConstraint = lineNumberScrollView.widthAnchor.constraint(equalToConstant: 0)
        lineNumberWidthConstraint.isActive = true

        context.coordinator.codeTextView = textView
        context.coordinator.lineNumberView = lineNumberView
        context.coordinator.lineNumberScrollView = lineNumberScrollView
        context.coordinator.lineNumberWidthConstraint = lineNumberWidthConstraint
        syncScroll(codeTextView: textView, lineNumberView: lineNumberView)
        updateTextViews(codeTextView: textView, lineNumberView: lineNumberView, coordinator: context.coordinator)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let codeTextView = context.coordinator.codeTextView,
              let lineNumberView = context.coordinator.lineNumberView else { return }
        updateTextViews(codeTextView: codeTextView, lineNumberView: lineNumberView, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func updateTextViews(
        codeTextView: NSTextView,
        lineNumberView: NSTextView,
        coordinator: Coordinator
    ) {
        let codeFont = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        let lineNumberFont = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        let lineNumberWidth = lineNumberGutterWidth(lineCount: highlightedLines.count, font: lineNumberFont)
        let content = NSMutableAttributedString()
        let lineNumbers = NSMutableAttributedString()
        let codeParagraphStyle = NSMutableParagraphStyle()
        codeParagraphStyle.minimumLineHeight = lineHeight
        codeParagraphStyle.maximumLineHeight = lineHeight
        let lineNumberParagraphStyle = NSMutableParagraphStyle()
        lineNumberParagraphStyle.alignment = .right
        lineNumberParagraphStyle.minimumLineHeight = lineHeight
        lineNumberParagraphStyle.maximumLineHeight = lineHeight
        let lineNumberAttributes: [NSAttributedString.Key: Any] = [
            .font: lineNumberFont,
            .foregroundColor: NSColor(lineNumberTint ?? lineNumberColor),
            .paragraphStyle: lineNumberParagraphStyle
        ]

        for (index, row) in highlightedLines.enumerated() {
            lineNumbers.append(NSAttributedString(
                string: "\(row.number)",
                attributes: [
                    .font: lineNumberFont,
                    .foregroundColor: NSColor(row.accentColor ?? lineNumberTint ?? lineNumberColor),
                    .paragraphStyle: lineNumberParagraphStyle
                ]
            ))
            let lineContent = NSMutableAttributedString(string: row.text, attributes: [
                .font: codeFont,
                .foregroundColor: NSColor(Color(tmRGBA: defaultForeground)),
                .paragraphStyle: codeParagraphStyle
            ])
            lineContent.setAttributedString(tmAttributedLine(
                sampleLine: row.text,
                tokens: row.tokens,
                colorPalette: colorPalette,
                defaultForeground: defaultForeground,
                editorBackground: editorBackground,
                font: codeFont,
                highlightedRanges: row.emphasizedRanges
            ))
            if let backgroundColor = row.backgroundColor {
                lineContent.addAttribute(
                    .backgroundColor,
                    value: NSColor(backgroundColor),
                    range: NSRange(location: 0, length: lineContent.length)
                )
            }
            content.append(lineContent)
            if index < highlightedLines.count - 1 {
                lineNumbers.append(NSAttributedString(string: "\n", attributes: lineNumberAttributes))
                content.append(NSAttributedString(string: "\n", attributes: [
                    .font: codeFont,
                    .paragraphStyle: codeParagraphStyle
                ]))
            }
        }

        content.addAttribute(.paragraphStyle, value: codeParagraphStyle, range: NSRange(location: 0, length: content.length))
        codeTextView.textStorage?.setAttributedString(content)
        lineNumberView.textStorage?.setAttributedString(lineNumbers)
        coordinator.lineNumberWidthConstraint?.constant = lineNumberWidth

        resizeTextView(codeTextView)
        resizeTextView(lineNumberView, fixedWidth: lineNumberWidth)
    }

    private func lineNumberGutterWidth(lineCount: Int, font: NSFont) -> CGFloat {
        let digitCount = String(max(1, lineCount)).count
        let charWidth = ceil(("0" as NSString).size(withAttributes: [.font: font]).width)
        return CGFloat(digitCount) * charWidth + lineNumberSpacing
    }

    private func resizeTextView(_ textView: NSTextView, fixedWidth: CGFloat? = nil) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let width = fixedWidth ?? ceil(usedRect.width + textView.textContainerInset.width * 2)
        let height = ceil(usedRect.height + textView.textContainerInset.height * 2)

        textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        textView.minSize = NSSize(width: width, height: height)
    }

    private func syncScroll(codeTextView: NSTextView, lineNumberView: NSTextView) {
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: codeTextView.enclosingScrollView?.contentView,
            queue: .main
        ) { _ in
            guard let clipView = codeTextView.enclosingScrollView?.contentView else { return }
            guard let lineNumberClipView = lineNumberView.enclosingScrollView?.contentView else { return }
            var point = lineNumberClipView.bounds.origin
            point.y = clipView.bounds.origin.y
            lineNumberClipView.scroll(to: point)
            lineNumberView.enclosingScrollView?.reflectScrolledClipView(lineNumberClipView)
        }
    }

    final class Coordinator {
        weak var codeTextView: NSTextView?
        weak var lineNumberView: NSTextView?
        weak var lineNumberScrollView: NSScrollView?
        var lineNumberWidthConstraint: NSLayoutConstraint?
    }
}

struct ContentView: View {
    private enum ThemeChoice: String, CaseIterable, Identifiable {
        case light
        case dark

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var resourceName: String {
            switch self {
            case .light: "pierre-light"
            case .dark: "pierre-dark"
            }
        }
    }

    private struct LoadedPreview {
        let palette: [String]
        let editorBackground: Color
        let editorBackgroundRGBA: TMRGBA
        let editorForegroundRGBA: TMRGBA
        let lineNumberColor: Color
        let oldLines: [DiffCodeLine]
        let newLines: [DiffCodeLine]
    }

    private struct DemoDiffColumn {
        let changedLineNumbers: Set<Int>
        let accentColor: Color
        let backgroundColor: Color
        let inlineHighlights: [Int: [String]]
    }

    @State private var selectedTheme: ThemeChoice = .light
    @State private var preview: LoadedPreview?

    init() {
        _preview = State(initialValue: Self.loadPreview(theme: .light))
    }

    /// Multi-line sample; `tokenizeLine2` state is carried line-to-line like VS Code.
    private static let demoOldRustLines: [String] = [
        "use std::io;",
        "",
        "fn main() {",
        "    println!(\"What is your name?\");",
        "    let mut name = String::new();",
        "    io::stdin().read_line(&mut name).unwrap();",
        "    println!(\"Hello, {}\", name.trim());",
        "}",
        "",
        "fn add(x: i32, y: i32) -> i32 {",
        "    return x + y;",
        "}",
    ]

    private static let demoNewRustLines: [String] = [
        "use std::io;",
        "",
        "fn main() {",
        "    println!(\"Enter your name:\");",
        "    let mut name = String::new();",
        "    io::stdin().read_line(&mut name).expect(\"read error\");",
        "    println!(\"Hello, {}!\", name.trim());",
        "}",
        "",
        "fn add(a: i32, b: i32) -> i32 {",
        "    a + b",
        "}",
    ]

    private static func ranges(for fragments: [String], in line: String) -> [NSRange] {
        let nsLine = line as NSString
        return fragments.compactMap { fragment in
            let range = nsLine.range(of: fragment)
            return range.location == NSNotFound ? nil : range
        }
    }

    private static func buildDiffColumn(
        lines: [String],
        grammar: Grammar,
        column: DemoDiffColumn
    ) throws -> [DiffCodeLine] {
        var stack: StateStackImpl?
        var output: [DiffCodeLine] = []

        for (index, line) in lines.enumerated() {
            let tokenized = try grammar.tokenizeLine2(lineText: line, prevState: stack, timeLimitMs: 0)
            let lineNumber = index + 1
            output.append(DiffCodeLine(
                number: lineNumber,
                text: line,
                tokens: Array(tokenized.tokens),
                backgroundColor: column.changedLineNumbers.contains(lineNumber) ? column.backgroundColor : nil,
                accentColor: column.changedLineNumbers.contains(lineNumber) ? column.accentColor : nil,
                emphasizedRanges: ranges(for: column.inlineHighlights[lineNumber] ?? [], in: line)
            ))
            stack = tokenized.ruleStack
        }

        return output
    }

    private static func loadPreview(theme: ThemeChoice) -> LoadedPreview? {
        var pal: [String] = []
        var bgRGBA = TMRGBA(tmHex: "#101010")!
        var fgRGBA = TMRGBA(tmHex: "#FFFFFF")!
        var lineNo = Color.white.opacity(0.45)
        var oldLines: [DiffCodeLine] = []
        var newLines: [DiffCodeLine] = []

        do {
            let gramURL = Bundle.main.url(forResource: "rust", withExtension: "json")!
            let themeURL = Bundle.main.url(forResource: theme.resourceName, withExtension: "json")!

            let themeData = try Data(contentsOf: themeURL)
            let themeDecoded = try tmDecodeRawThemeJSON(data: themeData)
            let themeObj = Theme.createFromRawTheme(source: themeDecoded, colorMap: nil)
            pal = themeObj.getColorMap()
            if let hex = tmEditorBackgroundHex(fromThemeJSON: themeData) {
                bgRGBA = TMRGBA(tmHex: hex) ?? bgRGBA
            }
            if let hex = tmEditorForegroundHex(fromThemeJSON: themeData) {
                fgRGBA = TMRGBA(tmHex: hex) ?? fgRGBA
            }
            if let hex = tmEditorLineNumberHex(fromThemeJSON: themeData),
               let lineRGBA = TMRGBA(tmHex: hex) {
                let visible = lineRGBA.composited(on: bgRGBA)
                lineNo = if visible.contrastDistance(from: bgRGBA) < 0.4 {
                    Color(tmRGBA: fgRGBA).opacity(0.55)
                } else {
                    Color(tmRGBA: visible)
                }
            }

            let grammarPayload = try TMJSONGrammar.decode(data: Data(contentsOf: gramURL))
            let grammarReady = tmInitGrammar(grammarPayload)

            let sync = SyncRegistry(theme: themeObj, onigLib: TMOnigAdapter())
            sync.addGrammar(grammarReady)

            guard let grammar = try sync.grammarForScopeName(
                scopeName: grammarReady.scopeName,
                initialLanguage: 1,
                embeddedLanguages: nil,
                tokenTypes: nil,
                balancedBracketSelectors: nil
            ) else {
                return nil
            }
            oldLines = try buildDiffColumn(
                lines: demoOldRustLines,
                grammar: grammar,
                column: DemoDiffColumn(
                    changedLineNumbers: [4, 6, 7, 10, 11],
                    accentColor: Color(red: 1, green: 0.29, blue: 0.31),
                    backgroundColor: Color(red: 1, green: 0.38, blue: 0.34).opacity(0.14),
                    inlineHighlights: [
                        4: ["What is", "name?"],
                        6: ["unwrap"],
                        7: ["{}"],
                        10: ["x", "y"],
                        11: ["return", "x", "y"]
                    ]
                )
            )
            newLines = try buildDiffColumn(
                lines: demoNewRustLines,
                grammar: grammar,
                column: DemoDiffColumn(
                    changedLineNumbers: [4, 6, 7, 10, 11],
                    accentColor: Color(red: 0.11, green: 0.79, blue: 0.67),
                    backgroundColor: Color(red: 0.2, green: 0.86, blue: 0.73).opacity(0.14),
                    inlineHighlights: [
                        4: ["Enter", "name:"],
                        6: ["expect", "read error"],
                        7: ["!"],
                        10: ["a", "b"],
                        11: ["a", "b"]
                    ]
                )
            )
        } catch {
            print("ContentView bootstrap failed for theme \(theme.resourceName): \(error)")
            return nil
        }

        return LoadedPreview(
            palette: pal,
            editorBackground: Color(tmRGBA: bgRGBA),
            editorBackgroundRGBA: bgRGBA,
            editorForegroundRGBA: fgRGBA,
            lineNumberColor: lineNo,
            oldLines: oldLines,
            newLines: newLines
        )
    }

    private func diffColumnTitle(_ title: String, color: Color) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 4)
                .stroke(color, lineWidth: 2)
                .frame(width:16, height:16)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(tmRGBA: preview?.editorForegroundRGBA ?? TMRGBA(tmHex: "#111111")!))
            Spacer()
        }
    }

    private func diffStat(value: String, color: Color) -> some View {
        Text(value)
            .font(.system(size: 14, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
    }

    private var nextTheme: ThemeChoice {
        selectedTheme == .light ? .dark : .light
    }

    @ViewBuilder
    private func floatingThemeButton(preview: LoadedPreview) -> some View {
        Button {
            selectedTheme = nextTheme
        } label: {
            Image(systemName: selectedTheme == .light ? "moon.stars.fill" : "sun.max.fill")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(tmRGBA: preview.editorForegroundRGBA))
        .background(
            Circle()
                .fill(preview.editorBackground.opacity(0.88))
        )
        .overlay(
            Circle()
                .stroke(Color(tmRGBA: preview.editorForegroundRGBA).opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
        .onHover { isHovering in
            if isHovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help("Switch to \(nextTheme.title) theme")
    }

    /// Best-effort read of `colors.editor.background` from raw theme JSON.
    private static func tmEditorBackgroundHex(fromThemeJSON data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let colors = obj["colors"] as? [String: Any],
              let hex = colors["editor.background"] as? String
        else { return nil }
        return hex
    }

    private static func tmEditorForegroundHex(fromThemeJSON data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let colors = obj["colors"] as? [String: Any],
              let hex = colors["editor.foreground"] as? String
        else { return nil }
        return hex
    }

    private static func tmEditorLineNumberHex(fromThemeJSON data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let colors = obj["colors"] as? [String: Any],
              let hex = colors["editorLineNumber.foreground"] as? String
        else { return nil }
        return hex
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            (preview?.editorBackground ?? Color.black)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                if let preview, !preview.oldLines.isEmpty, !preview.newLines.isEmpty {
                    VStack(spacing: 0) {
                        HStack(alignment: .center) {
                            diffColumnTitle("main.rs", color: Color.blue)
                            Spacer()
                            diffStat(value: "-5", color: Color(red: 1, green: 0.29, blue: 0.31))
                            diffStat(value: "+5", color: Color(red: 0.11, green: 0.79, blue: 0.67))
                        }
                        .padding(.bottom, 8)

                        HStack(spacing: 0) {
                            SelectableCodeTextView(
                                highlightedLines: preview.oldLines,
                                colorPalette: preview.palette,
                                defaultForeground: preview.editorForegroundRGBA,
                                editorBackground: preview.editorBackgroundRGBA,
                                lineNumberColor: preview.lineNumberColor,
                                lineNumberTint: nil
                            )


                            SelectableCodeTextView(
                                highlightedLines: preview.newLines,
                                colorPalette: preview.palette,
                                defaultForeground: preview.editorForegroundRGBA,
                                editorBackground: preview.editorBackgroundRGBA,
                                lineNumberColor: preview.lineNumberColor,
                                lineNumberTint: nil
                            )
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    Text("Failed to load grammar or theme resources.")
                        .foregroundStyle(.red)
                        .padding(16)
                }
            }
            .padding(12)

            if let preview {
                VStack {
                    Spacer()

                    HStack {
                        Spacer()
                        floatingThemeButton(preview: preview)
                    }
                }
                .padding(8)
            }
        }
        .onChange(of: selectedTheme) { _, newTheme in
            preview = Self.loadPreview(theme: newTheme)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 980, minHeight: 420)
    }
}

#Preview {
    ContentView()
}
