// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation

/// A compiled kcScript (`.kcs`): CatSystem2's C-like language, compiled to bytecode for a
/// stack machine. NEKOPARA Vol. 3 ships 14 in `kcs.int` (`sscript.kcs` is the scene engine:
/// it loads CatScene files and carries out their commands; `main.kcs`, `Select.kcs` and the
/// others are helpers) and more in `mot.int` and `ptcl.int` (motions, particles).
///
/// Worked out from the files themselves (no public description of the format was found):
///
/// - Header, thirteen `UInt32`s: `KCS\0`, version 2, 0, header size `0x34`, code size, code
///   size + `0x34`, string count, string table size, data size, stack size, file size, 0,
///   and a memory size. Then a zlib stream that inflates to the code followed by the string table.
/// - String table: `count` pairs (offset of the text from the table's start, address in the
///   data segment), then the NUL-terminated CP932 texts. The data segment is `dataSize` bytes
///   of zeros with these strings copied in; code refers to a string by its data address.
/// - Code: an opcode byte, then a fixed number of operands for that opcode (0 to 3), each a
///   mode byte and a 32-bit value. See `KCScript.Opcode` and `KCScript.Operand`.
public struct KCScript: Sendable {
    public let codeSize: Int
    public let dataSize: Int
    public let stackSize: Int
    /// Code followed by the string table, as inflated.
    public let body: [UInt8]
    /// Data address → text, for every string in the table.
    public let strings: [Int: String]
    /// The initial data segment (strings in place).
    public let data: [UInt8]

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public static func isKCS(_ bytes: [UInt8]) -> Bool { bytes.starts(with: [0x4B, 0x43, 0x53, 0x00]) }

    public init(_ bytes: [UInt8]) throws {
        guard Self.isKCS(bytes), bytes.count > 0x36 else { throw Failure(description: "not a kcScript file") }
        let headerSize = Int(bytes.le32(12))
        codeSize = Int(bytes.le32(16))
        let stringCount = Int(bytes.le32(24))
        let tableSize = Int(bytes.le32(28))
        dataSize = Int(bytes.le32(32))
        stackSize = Int(bytes.le32(36))
        guard headerSize == 0x34, headerSize < bytes.count else { throw Failure(description: "kcScript header size \(headerSize)") }
        body = try Zlib.inflate(bytes[headerSize...], size: codeSize + tableSize)
        var data = [UInt8](repeating: 0, count: dataSize)
        var strings: [Int: String] = [:]
        let table = codeSize
        guard table + stringCount * 8 <= body.count else { throw Failure(description: "kcScript string table runs off the end") }
        for i in 0..<stringCount {
            let textAt = table + Int(body.le32(table + i * 8))
            let address = Int(body.le32(table + i * 8 + 4))
            guard textAt < body.count else { throw Failure(description: "kcScript string \(i) out of range") }
            let raw = body.cString(textAt, max: body.count - textAt)
            strings[address] = String(data: Data(raw), encoding: cp932) ?? String(decoding: raw, as: UTF8.self)
            if address >= 0, address + raw.count < data.count {
                data.replaceSubrange(address..<address + raw.count, with: raw)
            }
        }
        self.strings = strings
        self.data = data
    }

    // MARK: Instructions

    /// The opcodes. Arithmetic and comparisons take two operands and push the result;
    /// assignments take a destination and a value and push the value stored; jumps pop
    /// the condition; `call` and `native` pop their arguments and push a result.
    public enum Opcode: UInt8, Sendable, CaseIterable {
        case add = 0x01, sub, mul, div, mod, and, or, bitNot, xor, shl, shr, not
        case logicalAnd = 0x0D, logicalOr, greater, less, greaterEqual, lessEqual, equal, notEqual
        case assign = 0x15, preIncrement, preDecrement, postIncrement, postDecrement, negate
        case modAssign = 0x1B, andAssign, divAssign, addAssign, subAssign, mulAssign
        case xorAssign = 0x21, shlAssign, shrAssign, orAssign
        case push = 0x25
        case jumpIfZero = 0x27, jumpIfNotZero, jump, call, native, ret
        case pushPointer = 0x2E, pushPointer2
        case alloc = 0x31, free, switchValue, caseValue, caseRange
        case unsignedToFloat = 0x36, intToFloat, floatToUnsigned, floatToInt
        case halt = 0x3B, pop, addressOfLocal, addressAdd

        /// Operands that follow the opcode.
        public var operandCount: Int {
            switch self {
            case .bitNot, .not, .preIncrement, .preDecrement, .postIncrement, .postDecrement, .negate,
                 .push, .jumpIfZero, .jumpIfNotZero, .jump, .pushPointer, .pushPointer2, .alloc, .free,
                 .unsignedToFloat, .intToFloat, .floatToUnsigned, .floatToInt, .addressOfLocal:
                1
            case .switchValue, .halt, .pop: 0
            case .caseRange: 3
            default: 2
            }
        }

        public var mnemonic: String {
            switch self {
            case .add: "add"
            case .sub: "sub"
            case .mul: "mul"
            case .div: "div"
            case .mod: "mod"
            case .and: "and"
            case .or: "or"
            case .bitNot: "bnot"
            case .xor: "xor"
            case .shl: "shl"
            case .shr: "shr"
            case .not: "not"
            case .logicalAnd: "land"
            case .logicalOr: "lor"
            case .greater: "gt"
            case .less: "lt"
            case .greaterEqual: "ge"
            case .lessEqual: "le"
            case .equal: "eq"
            case .notEqual: "ne"
            case .assign: "set"
            case .preIncrement: "preinc"
            case .preDecrement: "predec"
            case .postIncrement: "inc"
            case .postDecrement: "dec"
            case .negate: "neg"
            case .modAssign: "mod="
            case .andAssign: "and="
            case .divAssign: "div="
            case .addAssign: "add="
            case .subAssign: "sub="
            case .mulAssign: "mul="
            case .xorAssign: "xor="
            case .shlAssign: "shl="
            case .shrAssign: "shr="
            case .orAssign: "or="
            case .push: "push"
            case .jumpIfZero: "jz"
            case .jumpIfNotZero: "jnz"
            case .jump: "jmp"
            case .call: "call"
            case .native: "native"
            case .ret: "ret"
            case .pushPointer: "pushp"
            case .pushPointer2: "pushp2"
            case .alloc: "alloc"
            case .free: "free"
            case .switchValue: "switch"
            case .caseValue: "case"
            case .caseRange: "range"
            case .unsignedToFloat: "utof"
            case .intToFloat: "itof"
            case .floatToUnsigned: "ftou"
            case .floatToInt: "ftoi"
            case .halt: "halt"
            case .pop: "pop"
            case .addressOfLocal: "lea"
            case .addressAdd: "addr"
            }
        }
    }

    /// An operand: a mode byte and a 32-bit value.
    ///
    /// The mode's low four bits are the type (`1` a byte, `3` an int, `4` a float, `6` a
    /// pointer). The high four bits say where the value comes from: bit `0x40` set, it is popped
    /// from the stack, else it is the operand's value; bit `0x10` set, that is an address
    /// and the operand is what is stored there; bit `0x80` makes the type a pointer to the low
    /// four bits' type (a four-byte address). Bit `0x20` makes no difference to the value
    /// (the compiler sets it on temporaries). So `03 5` is the number 5, `13 0x40` the int at
    /// data address 0x40, `63` a value popped from the stack, `73` the int at an address popped
    /// from the stack, and `f1` the `char *` stored at a popped address.
    public struct Operand: Sendable, Equatable {
        public let mode: UInt8
        public let value: UInt32

        public var type: UInt8 { mode & 0x0F }
        public var isPointer: Bool { mode & 0x80 != 0 }
        public var fromStack: Bool { mode & 0x40 != 0 }
        public var isMemory: Bool { mode & 0x10 != 0 }
        public var isFloat: Bool { !isPointer && type == 4 }
        /// Bytes stored at the address when the operand is a memory reference.
        public var width: Int { isPointer ? 4 : (type == 1 ? 1 : type == 2 ? 2 : 4) }
    }

    public struct Instruction: Sendable {
        public let address: Int
        public let opcode: Opcode
        public let operands: [Operand]
        public var size: Int { 1 + 5 * operands.count }
    }

    public func instruction(at address: Int) throws -> Instruction {
        guard address >= 0, address < codeSize else { throw Failure(description: String(format: "pc %06x outside the code", address)) }
        guard let opcode = Opcode(rawValue: body[address]) else {
            throw Failure(description: String(format: "unknown opcode %02x at %06x", body[address], address))
        }
        let count = opcode.operandCount
        guard address + 1 + 5 * count <= codeSize else { throw Failure(description: String(format: "instruction at %06x runs off the code", address)) }
        var operands: [Operand] = []
        operands.reserveCapacity(count)
        for i in 0..<count {
            let at = address + 1 + 5 * i
            operands.append(Operand(mode: body[at], value: body.le32(at + 1)))
        }
        return Instruction(address: address, opcode: opcode, operands: operands)
    }

    /// Every instruction from the start of the code to its end, in order.
    public func instructions() throws -> [Instruction] {
        var out: [Instruction] = []
        var pc = 0
        while pc < codeSize {
            let i = try instruction(at: pc)
            out.append(i)
            pc += i.size
        }
        return out
    }

    /// One line of disassembly: address, mnemonic, operands (`mode:value`, strings quoted).
    public func describe(_ i: Instruction) -> String {
        let operands = i.operands.map { o -> String in
            var text = String(format: "%02x:%x", o.mode, o.value)
            if o.mode & 0x50 == 0, let s = strings[Int(o.value)] { text += " \"\(s)\"" }
            return text
        }
        return String(format: "%06x  ", i.address) + i.opcode.mnemonic.padding(toLength: 7, withPad: " ", startingAt: 0)
            + operands.joined(separator: " ")
    }
}
