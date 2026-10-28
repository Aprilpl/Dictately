import SwiftUI

// MARK: - Markdown 块解析（TASK-156 · 纯函数；原型 transcribe-summary-markdown.md 同构）

/// AI 摘要 Markdown 解析：模型返回原文 → 块树（标题/段落/列表/表格/引用/分割线）。
/// 行内语法（**加粗** / `代码` / 链接）不在本层展开，保留原文交给 Foundation
/// `AttributedString(markdown:)` 按行内模式解析（渲染层 `inline`）。
/// 覆盖面 = 两大内置总结 Prompt 的产出形态 + 常见 LLM 输出；未识别结构按段落原样呈现。
enum SummaryMarkdown {
    enum Block: Equatable {
        case paragraph(String)
        /// level 1–6（`###` = 3）；渲染层映射卡片内标题层级。
        case heading(level: Int, text: String)
        case list(ordered: Bool, items: [Item])
        case table(header: [String], rows: [[String]])
        case quote(String)
        case divider
    }

    /// 列表项：行内文本 + 缩进 ≥2 列的子块（通常为一个嵌套列表）。
    struct Item: Equatable {
        var text: String
        var children: [Block]

        init(_ text: String, children: [Block] = []) {
            self.text = text
            self.children = children
        }
    }

    static func parse(_ raw: String) -> [Block] {
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var i = 0
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }
            if let heading = headingMatch(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                i += 1
                continue
            }
            if isDivider(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                i += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count,
                    lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">")
                {
                    var q = lines[i].trimmingCharacters(in: .whitespaces)
                    q = q.hasPrefix("> ") ? String(q.dropFirst(2)) : String(q.dropFirst())
                    quoted.append(q.trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: " ")))
                continue
            }
            if listMatch(line) != nil {
                flushParagraph()
                let (block, next) = parseList(lines, from: i)
                blocks.append(block)
                i = next
                continue
            }
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = tableCells(line)
                i += 2
                var rows: [[String]] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || !t.contains("|") { break }
                    rows.append(tableCells(lines[i]))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: 行匹配（手工解析，勿引入正则初始化开销）

    private static func headingMatch(_ line: String) -> (level: Int, text: String)? {
        var s = Substring(line)
        var level = 0
        while s.first == "#", level < 6 {
            level += 1
            s = s.dropFirst()
        }
        guard level >= 1, s.first == " " || s.first == "\t" else { return nil }
        var text = s.drop(while: { $0 == " " || $0 == "\t" })
        while text.hasSuffix("#") { text = text.dropLast() }
        let result = text.trimmingCharacters(in: .whitespaces)
        guard !result.isEmpty else { return nil }
        return (level, result)
    }

    private static func isDivider(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        return trimmed.allSatisfy({ $0 == "-" })
            || trimmed.allSatisfy({ $0 == "*" })
            || trimmed.allSatisfy({ $0 == "_" })
    }

    private struct ListMatch {
        let indent: Int
        let ordered: Bool
        let text: String
    }

    /// `- `/`* `/`+ ` 无序；`1. `/`1)` 有序。bullet 后必须跟空白（`---`/`**加粗**` 不会误判）。
    private static func listMatch(_ line: String) -> ListMatch? {
        var indent = 0
        var s = Substring(line)
        while let f = s.first, f == " " || f == "\t" {
            indent += f == "\t" ? 4 : 1
            s = s.dropFirst()
        }
        if let f = s.first, f == "-" || f == "*" || f == "+" {
            let after = s.dropFirst()
            guard after.first == " " || after.first == "\t" else { return nil }
            return ListMatch(
                indent: indent, ordered: false,
                text: String(after.drop(while: { $0 == " " || $0 == "\t" })))
        }
        let digits = s.prefix(while: \.isNumber)
        if !digits.isEmpty {
            let afterDigits = s.dropFirst(digits.count)
            if let sep = afterDigits.first, sep == "." || sep == ")" {
                let after = afterDigits.dropFirst()
                if after.first == " " || after.first == "\t" {
                    return ListMatch(
                        indent: indent, ordered: true,
                        text: String(after.drop(while: { $0 == " " || $0 == "\t" })))
                }
            }
        }
        return nil
    }

    /// 列表块解析：缩进 ≥ 基准+2 列 → 前一项的子块（递归）；有序/无序混排视为两个列表。
    private static func parseList(_ lines: [String], from start: Int) -> (Block, Int) {
        guard let first = listMatch(lines[start]) else {
            return (.paragraph(lines[start]), start + 1)
        }
        let base = first.indent
        var items: [Item] = []
        var i = start
        while i < lines.count {
            guard let m = listMatch(lines[i]), m.indent >= base, m.ordered == first.ordered
            else { break }
            if m.indent >= base + 2 {
                let (sub, next) = parseList(lines, from: i)
                if items.isEmpty {
                    items.append(Item("", children: [sub]))
                } else {
                    items[items.count - 1].children.append(sub)
                }
                i = next
                continue
            }
            items.append(Item(m.text))
            i += 1
        }
        return (.list(ordered: first.ordered, items: items), i)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if t.hasSuffix("|") { t = String(t.dropLast()).trimmingCharacters(in: .whitespaces) }
        guard !t.isEmpty, t.contains("-") else { return false }
        return t.components(separatedBy: "|").allSatisfy { cell in
            var body = cell.trimmingCharacters(in: .whitespaces)
            if body.hasPrefix(":") { body = String(body.dropFirst()) }
            if body.hasSuffix(":") { body = String(body.dropLast()) }
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t = String(t.dropFirst()) }
        if t.hasSuffix("|") { t = String(t.dropLast()) }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - Markdown 渲染（摘要卡正文；TASK-158 记忆化：块树 + 每槽位行内
// AttributedString 按 raw 串缓存——body 重算零 parse 零行内解析；§82 像素契约不变）

/// 行内主题：基础/加粗/行内代码三态（原型 .mdview —— 正文 text2、加粗与标题 text1、标记中性灰）。
private struct InlineStyle {
    var size: CGFloat
    var weight: Font.Weight = .regular
    var color: Color
    var boldWeight: Font.Weight = .semibold
    var boldColor: Color
    var monoSize: CGFloat = 11
}

extension SummaryMarkdown {
    /// 行内 Markdown → 主题化 AttributedString（Foundation 行内解析 + 逐 run 上主题；
    /// 属性写入走容器下标切片 `parsed[run.range]`——run 视图只读）。
    fileprivate static func inline(_ text: String, style: InlineStyle) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        var parsed = (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent
            var font = Font.system(size: style.size, weight: style.weight)
            var color = style.color
            var isCode = false
            if let intent {
                if intent.contains(.stronglyEmphasized) {
                    font = .system(size: style.size, weight: style.boldWeight)
                    color = style.boldColor
                }
                if intent.contains(.code) {
                    font = Theme.mono(style.monoSize)
                    color = style.boldColor
                    isCode = true
                }
            }
            parsed[run.range].swiftUI.font = font
            parsed[run.range].swiftUI.foregroundColor = color
            if isCode {
                parsed[run.range].swiftUI.backgroundColor = Theme.field
            }
        }
        return parsed
    }
}

/// 记忆化渲染块：每个文本槽位在构建期定型为带主题属性的 AttributedString
/// （标题字号按层级、表头/正文、引用降级）。主题安全：烘焙的是 Theme 语义
/// 动态色（NSColor dynamicProvider 随 NSApp.appearance 即时重解析），缓存不冻结浅/深主题。
enum SummaryRenderBlock: Equatable {
    case paragraph(AttributedString)
    case heading(level: Int, text: AttributedString)
    case list(ordered: Bool, items: [Item])
    case table(header: [AttributedString], rows: [[AttributedString]])
    case quote(AttributedString)
    case divider

    struct Item: Equatable {
        var text: AttributedString
        var children: [SummaryRenderBlock]
    }
}

/// raw 串 → 渲染块树的进程级缓存（TASK-158）。此前 `SummaryMarkdown.parse` +
/// 逐块 `AttributedString(markdown:)`（表格 R×C 次解析）直接写在 body 里，
/// 250ms ticker / 总结状态变化即全卡重算（demo 语料单卡 ≈0.6ms，实测基线）。
/// NSCache 线程安全、内存压力自逐出；countLimit 12 = 页面在视结果卡数上界。
enum SummaryMarkdownRender {
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 12
        return cache
    }()

    private final class Box {
        let blocks: [SummaryRenderBlock]
        init(_ blocks: [SummaryRenderBlock]) { self.blocks = blocks }
    }

    static func blocks(for raw: String) -> [SummaryRenderBlock] {
        let key = raw as NSString
        if let box = cache.object(forKey: key) { return box.blocks }
        let blocks = build(SummaryMarkdown.parse(raw))
        cache.setObject(Box(blocks), forKey: key)
        return blocks
    }

    private static func build(_ blocks: [SummaryMarkdown.Block]) -> [SummaryRenderBlock] {
        blocks.map(buildBlock)
    }

    private static func buildBlock(_ block: SummaryMarkdown.Block) -> SummaryRenderBlock {
        switch block {
        case .paragraph(let text):
            return .paragraph(SummaryMarkdown.inline(text, style: .body))
        case .heading(let level, let text):
            return .heading(level: level, text: SummaryMarkdown.inline(
                text, style: headingStyle(level: level)))
        case .list(let ordered, let items):
            return .list(ordered: ordered, items: items.map { item in
                SummaryRenderBlock.Item(
                    text: SummaryMarkdown.inline(item.text, style: .body),
                    children: build(item.children))
            })
        case .table(let header, let rows):
            return .table(
                header: header.map { SummaryMarkdown.inline($0, style: .tableHeader) },
                rows: rows.map { $0.map { SummaryMarkdown.inline($0, style: .tableBody) } })
        case .quote(let text):
            return .quote(SummaryMarkdown.inline(text, style: .quote))
        case .divider:
            return .divider
        }
    }

    /// 卡内标题层级（原型 .mdview h3/h4/h5）：#/## → 13.5；### → 13；更深 → 12.5。
    private static func headingStyle(level: Int) -> InlineStyle {
        let size: CGFloat = level <= 2 ? 13.5 : (level == 3 ? 13 : 12.5)
        return InlineStyle(
            size: size, weight: .semibold, color: Theme.text1,
            boldWeight: .semibold, boldColor: Theme.text1)
    }
}

/// 摘要正文 Markdown 渲染（标题层级 / 加粗 / 中性灰列表 / 表格 / 引用 / 分割线）。
struct SummaryMarkdownView: View {
    private let blocks: [SummaryRenderBlock]

    /// raw 串入口（调用方不再自行 parse——记忆化在 SummaryMarkdownRender 内）。
    init(raw: String) {
        self.blocks = SummaryMarkdownRender.blocks(for: raw)
    }

    /// 嵌套子块递归入口。
    init(blocks: [SummaryRenderBlock]) {
        self.blocks = blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, isFirst: index == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: SummaryRenderBlock, isFirst: Bool) -> some View {
        switch block {
        case .paragraph(let text):
            Text(text)
                .lineSpacing(4)
        case .heading(let level, let text):
            // 上边距 15/13/11 与 VStack spacing 7 的差额用 padding 补（首块不补）。
            let topPadding: CGFloat = isFirst ? 0 : (level <= 2 ? 8 : (level == 3 ? 6 : 4))
            Text(text)
                .lineSpacing(3)
                .padding(.top, topPadding)
        case .list(let ordered, let items):
            listView(ordered: ordered, items: items)
        case .table(let header, let rows):
            tableView(header: header, rows: rows)
        case .quote(let text):
            HStack(spacing: 0) {
                Rectangle().fill(Theme.line2).frame(width: 2)
                Text(text)
                    .lineSpacing(4)
                    .padding(.leading, 10)
            }
        case .divider:
            Rectangle().fill(Theme.line2).frame(height: 0.5)
        }
    }

    private func listView(ordered: Bool, items: [SummaryRenderBlock.Item]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if ordered {
                        Text("\(index + 1).")
                            .font(.system(size: 11.5))
                            .monospacedDigit()
                            .foregroundStyle(Theme.text3)
                    } else {
                        Text("•")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text3)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.text)
                            .lineSpacing(4)
                        if !item.children.isEmpty {
                            SummaryMarkdownView(blocks: item.children)
                                .padding(.leading, 14)
                        }
                    }
                }
            }
        }
    }

    private func tableView(header: [AttributedString], rows: [[AttributedString]]) -> some View {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return AnyView(EmptyView()) }
        return AnyView(
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { column in
                        tableCell(
                            header.count > column ? header[column] : AttributedString(""),
                            isHeader: true, column: column, columnCount: columnCount,
                            bottomLine: !rows.isEmpty, strongBottomLine: true)
                    }
                }
                ForEach(0..<rows.count, id: \.self) { row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { column in
                            tableCell(
                                rows[row].count > column ? rows[row][column] : AttributedString(""),
                                isHeader: false, column: column, columnCount: columnCount,
                                bottomLine: row < rows.count - 1, strongBottomLine: false)
                        }
                    }
                }
            }
            .overlay(Rectangle().strokeBorder(Theme.line, lineWidth: 0.5))
        )
    }

    /// 单元格：内边距 9/5 + 表头 fillSoft 底 + 列间/行间 hairline（表头底线 line2 加重）。
    private func tableCell(
        _ text: AttributedString, isHeader: Bool, column: Int, columnCount: Int,
        bottomLine: Bool, strongBottomLine: Bool
    ) -> some View {
        Text(text)
        .lineSpacing(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(isHeader ? Theme.fillSoft : .clear)
        .overlay(alignment: .trailing) {
            if column < columnCount - 1 {
                Rectangle().fill(Theme.line).frame(width: 0.5)
            }
        }
        .overlay(alignment: .bottom) {
            if bottomLine {
                Rectangle()
                    .fill(strongBottomLine ? Theme.line2 : Theme.line)
                    .frame(height: 0.5)
            }
        }
    }
}

private extension InlineStyle {
    /// 正文行内（12.5 · text2；加粗提级 text1）。
    static var body: InlineStyle {
        InlineStyle(
            size: 12.5, color: Theme.text2,
            boldWeight: .semibold, boldColor: Theme.text1)
    }

    /// 引用行内（降级 text3）。
    static var quote: InlineStyle {
        InlineStyle(
            size: 12.5, color: Theme.text3,
            boldWeight: .semibold, boldColor: Theme.text3)
    }

    /// 表头单元格（12 · semibold · text1）。
    static var tableHeader: InlineStyle {
        InlineStyle(
            size: 12, weight: .semibold, color: Theme.text1,
            boldWeight: .semibold, boldColor: Theme.text1)
    }

    /// 表格正文单元格（12 · text2；加粗提级 text1）。
    static var tableBody: InlineStyle {
        InlineStyle(
            size: 12, color: Theme.text2,
            boldWeight: .semibold, boldColor: Theme.text1)
    }
}
