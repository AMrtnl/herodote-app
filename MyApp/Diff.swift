import SwiftUI

// MARK: - Diff
// Word-level diff between a saved version and the current text, rendered as an
// AttributedString: additions in green, deletions in red strikethrough.

enum DiffSegment: Hashable {
    case equal(String)
    case inserted(String)
    case deleted(String)
}

/// `old` is the saved version, `new` is the current text.
func wordDiff(old: String, new: String) -> [DiffSegment] {
    var oldTokens = tokenizeWords(old)
    var newTokens = tokenizeWords(new)
    // Myers is O(n·d); above ~20k tokens fall back to line granularity
    if oldTokens.count + newTokens.count > 20_000 {
        oldTokens = old.components(separatedBy: "\n").map { $0 + "\n" }
        newTokens = new.components(separatedBy: "\n").map { $0 + "\n" }
    }

    let difference = newTokens.difference(from: oldTokens)
    var removals = Set<Int>()
    var insertions = Set<Int>()
    for change in difference {
        switch change {
        case .remove(let offset, _, _): removals.insert(offset)
        case .insert(let offset, _, _): insertions.insert(offset)
        }
    }

    var out: [DiffSegment] = []
    var i = 0, j = 0
    while i < oldTokens.count || j < newTokens.count {
        if i < oldTokens.count, removals.contains(i) {
            out.append(.deleted(oldTokens[i])); i += 1
        } else if j < newTokens.count, insertions.contains(j) {
            out.append(.inserted(newTokens[j])); j += 1
        } else if i < oldTokens.count, j < newTokens.count {
            out.append(.equal(newTokens[j])); i += 1; j += 1
        } else {
            break
        }
    }
    return coalesce(out)
}

func diffAttributedString(_ segments: [DiffSegment]) -> AttributedString {
    var result = AttributedString()
    for segment in segments {
        switch segment {
        case .equal(let s):
            var a = AttributedString(s)
            a.foregroundColor = .primary
            result += a
        case .inserted(let s):
            var a = AttributedString(s)
            a.foregroundColor = .green
            a.backgroundColor = Color.green.opacity(0.15)
            result += a
        case .deleted(let s):
            var a = AttributedString(s)
            a.foregroundColor = .red
            a.strikethroughStyle = .single
            result += a
        }
    }
    return result
}

// MARK: - Private

/// Tokens keep their trailing whitespace so concatenation reconstructs the text.
private func tokenizeWords(_ s: String) -> [String] {
    guard !s.isEmpty else { return [] }
    let ns = s as NSString
    let regex = try! NSRegularExpression(pattern: "\\S+\\s*|\\s+")
    return regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range) }
}

private func coalesce(_ segments: [DiffSegment]) -> [DiffSegment] {
    var out: [DiffSegment] = []
    for segment in segments {
        switch (out.last, segment) {
        case (.equal(let a)?, .equal(let b)):       out[out.count - 1] = .equal(a + b)
        case (.inserted(let a)?, .inserted(let b)): out[out.count - 1] = .inserted(a + b)
        case (.deleted(let a)?, .deleted(let b)):   out[out.count - 1] = .deleted(a + b)
        default:                                    out.append(segment)
        }
    }
    return out
}
