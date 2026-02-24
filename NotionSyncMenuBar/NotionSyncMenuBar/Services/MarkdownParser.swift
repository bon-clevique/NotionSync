import Foundation

struct MarkdownParser: Sendable {

    func parse(_ content: String) -> [NotionBlock] {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        var blocks: [NotionBlock] = []
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        var currentParagraph: [String] = []

        for rawLine in lines {
            let line = String(rawLine).replacingOccurrences(
                of: "\\s+$",
                with: "",
                options: .regularExpression
            )

            if line.hasPrefix("### ") {
                if !currentParagraph.isEmpty {
                    blocks.append(makeParagraph(currentParagraph.joined(separator: "\n")))
                    currentParagraph = []
                }
                blocks.append(.heading3(String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                if !currentParagraph.isEmpty {
                    blocks.append(makeParagraph(currentParagraph.joined(separator: "\n")))
                    currentParagraph = []
                }
                blocks.append(.heading2(String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                if !currentParagraph.isEmpty {
                    blocks.append(makeParagraph(currentParagraph.joined(separator: "\n")))
                    currentParagraph = []
                }
                blocks.append(.heading1(String(line.dropFirst(2))))
            } else if line.isEmpty {
                if !currentParagraph.isEmpty {
                    blocks.append(makeParagraph(currentParagraph.joined(separator: "\n")))
                    currentParagraph = []
                }
            } else {
                currentParagraph.append(line)
            }
        }

        if !currentParagraph.isEmpty {
            blocks.append(makeParagraph(currentParagraph.joined(separator: "\n")))
        }

        return blocks
    }

    // MARK: - Private

    private func makeParagraph(_ text: String) -> NotionBlock {
        let truncated = text.count > 2000 ? String(text.prefix(1997)) + "..." : text
        return .paragraph(truncated)
    }
}
