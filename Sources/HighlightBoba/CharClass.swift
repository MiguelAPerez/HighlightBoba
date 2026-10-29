/// A set of UTF-16 code units written like a regex character class: `[a-z_]`, `[^"\\]`, `[\d.]`.
///
/// Only BMP characters can appear in a class; surrogate halves never match a non-negated class.
struct CharClass: Sendable {
    let ranges: [ClosedRange<UInt16>]
    let negated: Bool
    private let asciiLow: UInt64
    private let asciiHigh: UInt64

    init(ranges: [ClosedRange<UInt16>], negated: Bool) {
        self.ranges = ranges
        self.negated = negated
        var low: UInt64 = 0
        var high: UInt64 = 0
        for unit in UInt16(0)..<128 where ranges.contains(where: { $0.contains(unit) }) != negated {
            if unit < 64 { low |= 1 << UInt64(unit) } else { high |= 1 << UInt64(unit - 64) }
        }
        asciiLow = low
        asciiHigh = high
    }

    @inline(__always)
    func contains(_ unit: UInt16) -> Bool {
        if unit < 64 { return asciiLow & (1 << UInt64(unit)) != 0 }
        if unit < 128 { return asciiHigh & (1 << UInt64(unit - 64)) != 0 }
        return ranges.contains(where: { $0.contains(unit) }) != negated
    }

    static func parse(_ source: String) throws -> CharClass {
        var scalars = Array(source.unicodeScalars)
        guard scalars.count >= 3, scalars.first == "[", scalars.last == "]" else {
            throw GrammarError("character class \(source.debugDescription) must look like [...]")
        }
        scalars = Array(scalars[1..<(scalars.count - 1)])
        var index = 0
        var negated = false
        if scalars.first == "^" {
            negated = true
            index = 1
        }
        var ranges: [ClosedRange<UInt16>] = []

        func unit(_ scalar: Unicode.Scalar) throws -> UInt16 {
            guard scalar.value <= 0xFFFF, !(0xD800...0xDFFF).contains(scalar.value) else {
                throw GrammarError("character class \(source.debugDescription) contains a character outside the BMP")
            }
            return UInt16(scalar.value)
        }
        func escaped(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
            switch scalar {
            case "n": return "\n"
            case "t": return "\t"
            case "r": return "\r"
            default: return scalar
            }
        }

        while index < scalars.count {
            var scalar = scalars[index]
            index += 1
            if scalar == "\\" {
                guard index < scalars.count else {
                    throw GrammarError("character class \(source.debugDescription) ends with a lone backslash")
                }
                let next = scalars[index]
                index += 1
                switch next {
                case "d": ranges.append(48...57); continue
                case "w": ranges += [48...57, 65...90, 95...95, 97...122]; continue
                case "s": ranges += [9...13, 32...32]; continue
                default: scalar = escaped(next)
                }
            }
            let low = try unit(scalar)
            if index + 1 < scalars.count, scalars[index] == "-" {
                var upper = scalars[index + 1]
                index += 2
                if upper == "\\" {
                    guard index < scalars.count else {
                        throw GrammarError("character class \(source.debugDescription) ends with a lone backslash")
                    }
                    upper = escaped(scalars[index])
                    index += 1
                }
                let high = try unit(upper)
                guard low <= high else {
                    throw GrammarError("character class \(source.debugDescription) has a reversed range")
                }
                ranges.append(low...high)
            } else {
                ranges.append(low...low)
            }
        }
        guard !ranges.isEmpty else { throw GrammarError("character class \(source.debugDescription) is empty") }
        return CharClass(ranges: ranges, negated: negated)
    }
}
