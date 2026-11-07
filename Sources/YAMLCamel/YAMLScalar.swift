import Foundation

/// Resolves a plain scalar's text against the YAML 1.2.2 core schema.
///
/// The core schema leaves `yes`, `no`, `on` and `off` as strings, and has no sexagesimal form, so
/// `20:03:20` stays a string. Both of those are YAML 1.1 behaviour that 1.2 dropped.
enum YAMLScalar {

    /// Resolves plain scalar text to a typed value. Text that matches nothing resolves to a string.
    static func resolve(_ s: String) -> YAMLValue {
        switch s {
        case "", "~", "null", "Null", "NULL":
            return .null
        case "true", "True", "TRUE":
            return .bool(true)
        case "false", "False", "FALSE":
            return .bool(false)
        case ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF":
            return .double(.infinity)
        case "-.inf", "-.Inf", "-.INF":
            return .double(-.infinity)
        case ".nan", ".NaN", ".NAN":
            return .double(.nan)
        default:
            break
        }
        if let i = parseInteger(s) { return .int(i) }
        if let u = parseUnsignedInteger(s) { return .uint(u) }
        if let d = parseFloat(s) { return .double(d) }
        return .string(s)
    }

    /// Parses the core-schema integer forms: signed decimal, unsigned `0o` octal, unsigned `0x` hex.
    /// Returns nil for anything else, including a value too large for `Int`.
    static func parseInteger(_ s: String) -> Int? {
        let u = Array(s.unicodeScalars)
        guard !u.isEmpty else { return nil }

        if u.count > 2, u[0] == "0", u[1] == "o" {
            return radixValue(u[2...], radix: 8)
        }
        if u.count > 2, u[0] == "0", u[1] == "x" {
            return radixValue(u[2...], radix: 16)
        }

        var k = 0
        if u[0] == "+" || u[0] == "-" { k = 1 }
        guard k < u.count else { return nil }
        for j in k ..< u.count where !isDigit(u[j]) { return nil }
        // `Int(_:)` covers the whole signed range, including a magnitude only the negative end has.
        return Int(s)
    }

    /// Parses a plain decimal integer too large for `Int` but not for `UInt64`, the shape a `UInt64`
    /// above `Int64.max` takes on the page. Returns nil for anything signed, radix-prefixed, or
    /// outside `UInt64` range.
    static func parseUnsignedInteger(_ s: String) -> UInt64? {
        let u = Array(s.unicodeScalars)
        guard !u.isEmpty else { return nil }
        var k = 0
        if u[0] == "+" { k = 1 }
        guard k < u.count else { return nil }
        for j in k ..< u.count where !isDigit(u[j]) { return nil }
        return UInt64(k == 0 ? s : String(s.dropFirst()))
    }

    /// Parses the core-schema float forms, which need a decimal point or an exponent. Returns nil for
    /// anything else. The special values `.inf` and `.nan` are handled by `resolve`.
    static func parseFloat(_ s: String) -> Double? {
        let u = Array(s.unicodeScalars)
        guard !u.isEmpty else { return nil }

        var k = 0
        if u[k] == "+" || u[k] == "-" { k += 1 }

        var sawDigit = false
        var sawDot = false
        while k < u.count, isDigit(u[k]) { sawDigit = true; k += 1 }
        if k < u.count, u[k] == "." {
            sawDot = true
            k += 1
            var fractionDigits = false
            while k < u.count, isDigit(u[k]) { fractionDigits = true; k += 1 }
            // The core schema allows `1.` but not a bare `.` with nothing on either side.
            if !sawDigit && !fractionDigits { return nil }
            sawDigit = sawDigit || fractionDigits
        }
        guard sawDigit else { return nil }

        var sawExponent = false
        if k < u.count, u[k] == "e" || u[k] == "E" {
            let save = k
            k += 1
            if k < u.count, u[k] == "+" || u[k] == "-" { k += 1 }
            var exponentDigits = false
            while k < u.count, isDigit(u[k]) { exponentDigits = true; k += 1 }
            if !exponentDigits { k = save } else { sawExponent = true }
        }

        guard k == u.count else { return nil }
        guard sawDot || sawExponent else { return nil }

        if let d = Double(s) { return d }
        // Swift rejects a trailing-dot form like `1.`, so normalise it.
        if s.hasSuffix(".") { return Double(s + "0") }
        return nil
    }

    private static func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }

    /// Reads digits in the given radix, refusing an empty run, a non-digit, or an overflow.
    private static func radixValue(_ digits: ArraySlice<Unicode.Scalar>, radix: Int) -> Int? {
        guard !digits.isEmpty else { return nil }
        var value = 0
        for c in digits {
            guard let d = hexValue(c), d < radix else { return nil }
            let (multiplied, overflowA) = value.multipliedReportingOverflow(by: radix)
            guard !overflowA else { return nil }
            let (added, overflowB) = multiplied.addingReportingOverflow(d)
            guard !overflowB else { return nil }
            value = added
        }
        return value
    }

    private static func hexValue(_ c: Unicode.Scalar) -> Int? {
        switch c {
        case "0" ... "9": return Int(c.value - 0x30)
        case "a" ... "f": return Int(c.value - 0x61) + 10
        case "A" ... "F": return Int(c.value - 0x41) + 10
        default: return nil
        }
    }
}
