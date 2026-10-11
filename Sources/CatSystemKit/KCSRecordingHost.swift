import Foundation

/// A host for headless kcScript runs: it carries out the few natives whose meaning is
/// clear from how the scripts use them (string copies and formatting, debug output) and
/// records every other call with its arguments, answering 0 (or `answers[id]`).
///
/// Natives worked out from use:
/// - `0x01` debug print of a format (`"sscript loaded > %s[L20]"`)
/// - `0x0d` copy a string (destination, source)
/// - `0x0e` format into a buffer (destination, format): the format names its values inline,
///   `%d[L64]` the int in the caller's frame at offset 64, `%s[L20]` the string there,
///   `[G165604]` data address 165604 instead of the frame
/// - `0x0d2` read engine variable `$n` (FES's numbered variables); `0x0d3` set one (n, value)
/// - `0x114` set string variable `$strN` (n, text); `0x115` copy it into a buffer (n, buffer);
///   `0x116` replace a buffer holding `$strN` with that variable's text
/// - `0x145` load a CatScene scene into a scene record (record, scene name); sscript calls
///   it with the scene the title screen chose (`$str200`, `01` for a new game)
/// - `0x146` a scene record's line type (record, ?, line), -1 past the end (here: no scene)
/// - `0x1bf` start a FES script (?, name); `main.kcs` starts `flow` with it
public final class KCSRecordingHost: KCSHost {
    public struct Call: Sendable {
        public let step: Int
        public let pc: Int
        public let id: Int
        public let args: [UInt32]
        public let note: String?
    }

    public private(set) var calls: [Call] = []
    public private(set) var printed: [String] = []
    /// Results for natives to answer with instead of 0.
    public var answers: [Int: UInt32] = [:]
    /// Engine variables (`$512` …) and string variables (`$str200` …).
    public var variables: [Int: Int] = [:]
    public var stringVariables: [Int: String] = [:]
    /// Stops the machine when this native is called (the caller checks `stopped`).
    public var stopAt: Set<Int> = []
    public private(set) var stopped: Call?

    /// Clears `stopped` and stops at these natives from now on.
    public func resetStop(_ ids: Set<Int>) {
        stopAt = ids
        stopped = nil
    }

    public init() {}

    public func native(_ id: Int, _ args: [UInt32], _ m: KCSMachine) -> UInt32 {
        var note: String?
        var result = answers[id] ?? 0
        switch id {
        case 0x01:
            let text = Self.format(m.string(at: args.first ?? 0), m)
            printed.append(text)
            note = text
        case 0x0D where args.count == 2:
            let text = m.string(at: args[1])
            m.writeString(text, at: args[0])
            note = "\"\(text)\""
        case 0x0E where args.count == 2:
            let text = Self.format(m.string(at: args[1]), m)
            m.writeString(text, at: args[0])
            note = "\"\(text)\""
        case 0xD2 where args.count == 1 && answers[id] == nil:
            let n = Int(Int32(bitPattern: args[0]))
            result = UInt32(truncatingIfNeeded: variables[n] ?? 0)
            note = "$\(n) = \(variables[n] ?? 0)"
        case 0xD3 where args.count == 2:
            let n = Int(Int32(bitPattern: args[0]))
            variables[n] = Int(Int32(bitPattern: args[1]))
            note = "$\(n) = \(Int32(bitPattern: args[1]))"
        case 0x114 where args.count == 2:
            let text = m.string(at: args[1])
            stringVariables[Int(args[0])] = text
            note = "$str\(args[0]) = \"\(text)\""
        case 0x115 where args.count == 2:
            let text = stringVariables[Int(args[0])] ?? ""
            m.writeString(text, at: args[1])
            note = "$str\(args[0]) → \"\(text)\""
        case 0x146 where answers[id] == nil:
            result = 0xFFFF_FFFF
        case 0x1BF where args.count == 2:
            note = "start FES \"\(m.string(at: args[1]))\""
        case 0x116 where args.count == 1:
            // Expands `$strN` in place (inferred: the scripts format "$str%d" and then call this).
            let text = m.string(at: args[0])
            if text.hasPrefix("$str"), let n = Int(text.dropFirst(4)), let value = stringVariables[n] {
                m.writeString(value, at: args[0])
                note = "\(text) → \"\(value)\""
            } else {
                note = "\"\(text)\""
            }
        case 0x145 where args.count == 2:
            note = "load scene \"\(m.string(at: args[1]))\""
        default:
            let strings = args.compactMap { a -> String? in
                guard a < UInt32(m.script.dataSize), let s = m.script.strings[Int(a)] else { return nil }
                return "\"\(s)\""
            }
            if !strings.isEmpty { note = strings.joined(separator: " ") }
        }
        let call = Call(step: m.steps, pc: m.pc, id: id, args: args, note: note)
        calls.append(call)
        if stopAt.contains(id), stopped == nil { stopped = call; result = 0 }
        return result
    }

    /// Fills a kcScript format's inline references (`%d[L64]`, `%s[G165604]`, `%x[L92]`).
    public static func format(_ pattern: String, _ m: KCSMachine) -> String {
        var out = ""
        let chars = Array(pattern)
        var i = 0
        while i < chars.count {
            guard chars[i] == "%", i + 1 < chars.count else { out.append(chars[i]); i += 1; continue }
            var j = i + 1
            var spec = "%"
            while j < chars.count, "0123456789-.lh".contains(chars[j]) { spec.append(chars[j]); j += 1 }
            guard j < chars.count else { out.append(contentsOf: spec); break }
            let conversion = chars[j]
            if conversion == "%" { out.append("%"); i = j + 1; continue }
            j += 1
            var address: UInt32?
            if j < chars.count, chars[j] == "[", let close = chars[j...].firstIndex(of: "]") {
                let reference = String(chars[(j + 1)..<close])
                if let n = UInt32(reference.dropFirst()) {
                    address = reference.hasPrefix("L") ? m.frameAddress + n : n
                }
                j = close + 1
            }
            if let address {
                switch conversion {
                case "s": out += m.string(at: address)
                case "x", "X":
                    out += String(format: spec + "x", (try? m.load(address, width: 4)) ?? 0)
                default:
                    out += String(format: spec + "d", Int32(bitPattern: (try? m.load(address, width: 4)) ?? 0))
                }
            } else {
                out += spec + String(conversion)
            }
            i = j
        }
        return out
    }
}
