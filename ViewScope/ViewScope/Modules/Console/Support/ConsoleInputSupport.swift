import Foundation

/// Console 输入历史（↑/↓ 浏览），只保存在内存中。
struct ConsoleInputHistory: Equatable {
    private(set) var entries: [String] = []
    /// 当前浏览位置；nil 表示不在浏览状态（位于“新输入”处）。
    private(set) var cursor: Int?
    /// 开始浏览前用户已输入但未提交的草稿。
    private var draft = ""
    let capacity: Int

    init(capacity: Int = 100) {
        self.capacity = capacity
    }

    /// 提交一条命令：去掉与上一条相同的重复项，并重置浏览位置。
    mutating func record(_ expression: String) {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        cursor = nil
        draft = ""
        guard trimmed.isEmpty == false else {
            return
        }
        if entries.last != trimmed {
            entries.append(trimmed)
        }
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// ↑：返回更早的一条；已经到最早时停留在最早一条。
    mutating func previous(currentInput: String) -> String? {
        guard entries.isEmpty == false else {
            return nil
        }
        let nextCursor: Int
        if let cursor {
            nextCursor = max(0, cursor - 1)
        } else {
            draft = currentInput
            nextCursor = entries.count - 1
        }
        cursor = nextCursor
        return entries[nextCursor]
    }

    /// ↓：返回更新的一条；越过最新一条时恢复草稿。
    mutating func next() -> String? {
        guard let cursor else {
            return nil
        }
        if cursor + 1 < entries.count {
            self.cursor = cursor + 1
            return entries[cursor + 1]
        }
        self.cursor = nil
        return draft
    }

    mutating func resetBrowsing() {
        cursor = nil
        draft = ""
    }
}

/// 补全时需要替换的“当前单词”。
struct ConsoleCompletionToken: Equatable {
    /// 单词在输入中的范围（UTF-16 偏移，便于直接用于 NSTextView）。
    let range: NSRange
    let prefix: String

    /// 取光标前最后一个标识符片段（遇到 `.`、空格、`:` 等分隔符截止）。
    static func token(in text: String, cursorLocation: Int) -> ConsoleCompletionToken {
        let nsText = text as NSString
        let location = min(max(0, cursorLocation), nsText.length)
        var start = location
        while start > 0 {
            let character = nsText.character(at: start - 1)
            guard let scalar = Unicode.Scalar(character),
                  CharacterSet.alphanumerics.contains(scalar) || scalar == "_" else {
                break
            }
            start -= 1
        }
        let range = NSRange(location: start, length: location - start)
        return ConsoleCompletionToken(range: range, prefix: nsText.substring(with: range))
    }

    /// 用补全结果替换当前单词，返回新的文本和光标位置。
    func applying(_ completion: String, to text: String) -> (text: String, cursorLocation: Int) {
        let nsText = text as NSString
        let replaced = nsText.replacingCharacters(in: range, with: completion)
        return (replaced, range.location + (completion as NSString).length)
    }
}
