import Foundation

/// Renders a `YAMLValue` as block-style YAML text with a two-space indent.
///
/// Sequences sit at their key's indentation, matching libyaml's conventional output, and scalars are
/// quoted only when a plain scalar would be misread.
struct YAMLEmitter {
    let sortKeys: Bool
    let limits: YAMLEmitLimits

    /// Creates an emitter. Pass sortKeys for key order that does not depend on insertion order, and
    /// limits to bound what it will write.
    init(sortKeys: Bool, limits: YAMLEmitLimits = .default) {
        self.sortKeys = sortKeys
        self.limits = limits
    }

    func emit(_ value: YAMLValue) throws -> String {
        let budget = YAMLEmitBudget(limits: limits)
        var out = ""
        switch value {
        case .object(let members) where !members.isEmpty:
            try emitMapping(members, indent: 0, into: &out, budget: budget)
        case .array(let items) where !items.isEmpty:
            try emitSequence(items, indent: 0, into: &out, budget: budget)
        case .object:
            try budget.countNode()
            try append("{}\n", to: &out, budget: budget)
        case .array:
            try budget.countNode()
            try append("[]\n", to: &out, budget: budget)
        default:
            try budget.countNode()
            try append(emitScalar(value) + "\n", to: &out, budget: budget)
        }
        return out
    }

    private func append(_ text: String, to out: inout String, budget: YAMLEmitBudget) throws {
        try budget.spend(text)
        out += text
    }

    // MARK: mapping and sequence

    private func emitMapping(_ members: [YAMLValue.Member],
                             indent: Int,
                             into out: inout String,
                             budget: YAMLEmitBudget) throws {
        try budget.push()
        defer { budget.pop() }
        try budget.countNode()

        let ordered = sortKeys ? members.sorted { $0.key < $1.key } : members
        var seen = Set<String>()
        for m in ordered {
            guard seen.insert(m.key).inserted else {
                throw YAMLEmitError(.duplicateKey, "Mapping repeats the key \(m.key).")
            }
            let key = emitScalarString(m.key)
            switch m.value {
            case .object(let sub) where !sub.isEmpty:
                try append(pad(indent) + key + ":\n", to: &out, budget: budget)
                try emitMapping(sub, indent: indent + 2, into: &out, budget: budget)
            case .array(let sub) where !sub.isEmpty:
                try append(pad(indent) + key + ":\n", to: &out, budget: budget)
                try emitSequence(sub, indent: indent, into: &out, budget: budget)
            case .object:
                try budget.countNode()
                try append(pad(indent) + key + ": {}\n", to: &out, budget: budget)
            case .array:
                try budget.countNode()
                try append(pad(indent) + key + ": []\n", to: &out, budget: budget)
            default:
                try budget.countNode()
                try append(pad(indent) + key + ": " + emitScalar(m.value) + "\n", to: &out, budget: budget)
            }
        }
    }

    private func emitSequence(_ items: [YAMLValue],
                              indent: Int,
                              into out: inout String,
                              budget: YAMLEmitBudget) throws {
        try budget.push()
        defer { budget.pop() }
        try budget.countNode()

        for item in items {
            switch item {
            case .object(let sub) where !sub.isEmpty:
                // The nested buffer spends the same budget, and its bytes are charged once as they
                // are written into it rather than again when it is folded in here.
                var tmp = ""
                try emitMapping(sub, indent: indent + 2, into: &tmp, budget: budget)
                // The first key shares the dash line.
                out += pad(indent) + "- " + String(tmp.dropFirst(indent + 2))
            case .array(let sub) where !sub.isEmpty:
                try append(pad(indent) + "-\n", to: &out, budget: budget)
                try emitSequence(sub, indent: indent + 2, into: &out, budget: budget)
            case .object:
                try budget.countNode()
                try append(pad(indent) + "- {}\n", to: &out, budget: budget)
            case .array:
                try budget.countNode()
                try append(pad(indent) + "- []\n", to: &out, budget: budget)
            default:
                try budget.countNode()
                try append(pad(indent) + "- " + emitScalar(item) + "\n", to: &out, budget: budget)
            }
        }
    }

    // MARK: scalars

    private func emitScalar(_ value: YAMLValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .uint(let u): return String(u)
        case .double(let d): return YAMLValue.doubleText(d, keepPointZero: true)
        case .string(let s): return emitScalarString(s)
        case .array: return "[]"
        case .object: return "{}"
        }
    }

    /// A string scalar, plain when unambiguous and double-quoted otherwise.
    private func emitScalarString(_ s: String) -> String {
        needsQuoting(s) ? doubleQuoted(s) : s
    }

    private func needsQuoting(_ s: String) -> Bool {
        if s.isEmpty { return true }
        // A plain scalar that would re-read as null, a bool or a number has to be quoted.
        guard case .string(let round) = YAMLScalar.resolve(s), round == s else { return true }

        if s.hasPrefix("---") || s.hasPrefix("...") { return true }

        let u = Array(s.unicodeScalars)
        if isBlank(u[0]) || isBlank(u[u.count - 1]) { return true }

        // Any indicator character anywhere makes the plain form ambiguous somewhere: a quote or a
        // flow bracket mid-string is what the block parser's own key scanning trips over.
        for (k, c) in u.enumerated() {
            switch c {
            case "\n", "\r", "\t", "\u{85}", "\u{2028}", "\u{2029}":
                return true
            case "\u{FEFF}":
                // A byte order mark is stripped when it opens a stream, so a plain scalar loses it.
                return true
            case "\"", "'", "[", "]", "{", "}", ",", "#", "&", "*", "!", "|", ">", "%", "@", "`":
                return true
            case ":":
                if k + 1 == u.count || isBlank(u[k + 1]) { return true }
            case "-", "?":
                if k == 0, k + 1 == u.count || isBlank(u[k + 1]) { return true }
            default:
                if c.value < 0x20 || (0x7F...0x9F).contains(c.value) || c.value == 0xFFFE || c.value == 0xFFFF { return true }
            }
        }
        return false
    }

    private func isBlank(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" }

    private func doubleQuoted(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{85}": out += "\\N"
            case "\u{A0}": out += "\\_"
            case "\u{2028}": out += "\\L"
            case "\u{2029}": out += "\\P"
            case "\u{FEFF}": out += "\\uFEFF"
            default:
                if c.value < 0x20 || c.value == 0x7F {
                    out += String(format: "\\x%02X", c.value)
                } else if (0x80...0x9F).contains(c.value) || c.value == 0xFFFE || c.value == 0xFFFF {
                    out += String(format: "\\u%04X", c.value)
                } else {
                    out.unicodeScalars.append(c)
                }
            }
        }
        out += "\""
        return out
    }

    private func pad(_ n: Int) -> String { String(repeating: " ", count: n) }
}
