import Foundation

/// 转写文本循环塌缩检测（TASK-151 塌缩护栏，纯函数）。
///
/// 背景（2026-10-24 长音频实测，docs/test-long-audio/report.md）：Qwen3-ASR-0.6B-4bit
/// 在超长单次推理上下文（≥11 分钟整段）下必然进入复读机式循环——整段输出同一短句
/// （「谢谢。」×4093 /「那不光是一个城市所面临的局面。」到底），且以**成功形态**
/// 交付垃圾文本。切片转写后单段仍可能内容性地塌缩（对抗性噪声内容 3 片中 1 片），
/// 逐段检测结果驱动「对半重切降档」恢复路径（FileTranscribeController）。
///
/// 双判据（任一命中即塌缩）：
/// 1. **连续重复单元**：2–20 字符单元（含句读）连续出现 ≥6 次——正则懒惰分组，
///    覆盖带句读（「谢谢。」）与无句读（「哈哈哈哈」）两种循环形态；
/// 2. **句级覆盖率**：按句读切分去连续重后，剩余长度 ≤ 原文 35%——覆盖开头正常、
///    主体循环的混合形态。
///
/// 防误报：<60 字符不判（正常短听写不可能构成塌缩）；判据 1 需**连续** 6 次——
/// 真实语音中的排比/复句不会同一 2–20 字单元逐字连排 6 遍。
enum TranscriptCollapseDetector {
    /// 判定的最小文本长度（短于此一律不判）。
    static let minimumLength = 60
    /// 判据 1 的正则：懒惰分组取最短重复单元，{5,} = 首次之后至少再出现 5 次（共 6 次）。
    static let repeatPattern = #"(.{2,20}?)\1{5,}"#
    /// 判据 2 的覆盖率阈值（去连续重后 / 原文）。
    static let coverageThreshold = 0.35

    static func isCollapsed(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumLength else { return false }

        // 判据 1：连续重复单元
        if trimmed.range(of: repeatPattern, options: .regularExpression) != nil {
            return true
        }

        // 判据 2：句级去连续重覆盖率
        let clauses = trimmed.split(
            omittingEmptySubsequences: true,
            whereSeparator: { "。！？；，,.!?;\n".contains($0) })
        guard clauses.count >= 6 else { return false }
        var dedupedCount = clauses[0].count
        for index in 1..<clauses.count where clauses[index] != clauses[index - 1] {
            dedupedCount += clauses[index].count
        }
        let totalCount = clauses.reduce(0) { $0 + $1.count }
        return Double(dedupedCount) <= coverageThreshold * Double(totalCount)
    }
}
