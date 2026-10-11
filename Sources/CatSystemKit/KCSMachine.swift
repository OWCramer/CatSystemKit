import Foundation

/// What a kcScript asks of the engine: `native` calls, by number. Arguments are the
/// 32-bit words the script pushed, in push order; the result is pushed back.
public protocol KCSHost: AnyObject {
    func native(_ id: Int, _ args: [UInt32], _ machine: KCSMachine) -> UInt32
}

/// Runs a `KCScript`.
///
/// Memory is three regions in one 32-bit address space: the script's data segment at
/// addresses from 0, the stack from `stackBase`, and memory the engine shares between
/// scripts at addresses with the top bit set (`0x8000_0000 | offset`), which the host can
/// fill before running. The stack grows upwards. A call's frame starts at its arguments
/// (`lea 0` is the first), then three words the machine keeps (return address, the
/// caller's frame, the stack depth), then the locals `alloc` reserves in order. Operands
/// popped from the stack are popped in operand order (the compiler pushes them reversed).
public final class KCSMachine {
    public let script: KCScript
    public weak var host: KCSHost?
    public static let stackBase: UInt32 = 0x4000_0000
    public static let sharedBase: UInt32 = 0x8000_0000

    public private(set) var pc = 0
    public private(set) var halted = false
    public private(set) var steps = 0
    var data: [UInt8]
    var stack: [UInt8]
    var shared: [UInt8]
    var sp = 0
    var fp = 0
    var depth = 0

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public init(script: KCScript, sharedSize: Int = 0x10_0000, stackSize: Int = 0x10_0000) {
        self.script = script
        data = script.data
        stack = [UInt8](repeating: 0, count: max(stackSize, script.stackSize))
        shared = [UInt8](repeating: 0, count: sharedSize)
    }

    /// Starts over at `entry` (the code's first instruction calls the script's main function).
    public func reset(entry: Int = 0) {
        pc = entry
        sp = 0
        fp = 0
        depth = 0
        halted = false
    }

    /// The memory scripts share (`0x8000_0000` up): copy it from one machine to the next
    /// to run scripts one after another, as the engine does.
    public var sharedMemory: [UInt8] {
        get { shared }
        set { shared = newValue }
    }

    /// The frame pointer as an address (`lea 0`), for natives that read the caller's locals.
    public var frameAddress: UInt32 { Self.stackBase + UInt32(fp) }

    /// Runs until `halt` or `limit` instructions; throws on a malformed instruction or a bad address.
    public func run(limit: Int = 10_000_000) throws {
        var budget = limit
        while !halted, budget > 0 {
            try step()
            budget -= 1
        }
    }

    // MARK: Memory

    private enum Region { case data, stack, shared }

    private func region(_ address: UInt32, _ count: Int) throws -> (Region, Int) {
        let r: Region, offset: Int, size: Int
        if address >= Self.sharedBase {
            (r, offset, size) = (.shared, Int(address - Self.sharedBase), shared.count)
        } else if address >= Self.stackBase {
            (r, offset, size) = (.stack, Int(address - Self.stackBase), stack.count)
        } else {
            (r, offset, size) = (.data, Int(address), data.count)
        }
        guard offset + count <= size else {
            throw Failure(description: String(format: "address %08x out of range at pc %06x", address, pc))
        }
        return (r, offset)
    }

    public func load(_ address: UInt32, width: Int) throws -> UInt32 {
        let (r, o) = try region(address, width)
        func get(_ m: [UInt8]) -> UInt32 {
            switch width {
            case 1: return UInt32(bitPattern: Int32(Int8(bitPattern: m[o])))
            case 2: return UInt32(bitPattern: Int32(Int16(bitPattern: UInt16(m[o]) | UInt16(m[o + 1]) << 8)))
            default: return UInt32(m[o]) | UInt32(m[o + 1]) << 8 | UInt32(m[o + 2]) << 16 | UInt32(m[o + 3]) << 24
            }
        }
        switch r {
        case .data: return get(data)
        case .stack: return get(stack)
        case .shared: return get(shared)
        }
    }

    public func store(_ address: UInt32, _ value: UInt32, width: Int) throws {
        let (r, o) = try region(address, width)
        for i in 0..<width {
            let b = UInt8(truncatingIfNeeded: value >> (8 * i))
            switch r {
            case .data: data[o + i] = b
            case .stack: stack[o + i] = b
            case .shared: shared[o + i] = b
            }
        }
    }

    /// A NUL-terminated CP932 string in the script's memory.
    public func string(at address: UInt32) -> String {
        var bytes: [UInt8] = []
        var a = address
        while bytes.count < 4096, let b = try? load(a, width: 1), b & 0xFF != 0 {
            bytes.append(UInt8(b & 0xFF))
            a += 1
        }
        return String(data: Data(bytes), encoding: cp932) ?? String(decoding: bytes, as: UTF8.self)
    }

    /// Writes a NUL-terminated CP932 string (for natives that fill a buffer).
    public func writeString(_ text: String, at address: UInt32) {
        let bytes = (text.data(using: cp932).map { [UInt8]($0) } ?? Array(text.utf8)) + [0]
        for (i, b) in bytes.enumerated() { try? store(address + UInt32(i), UInt32(b), width: 1) }
    }

    // MARK: Stack

    func push(_ v: UInt32) throws {
        guard sp + 4 <= stack.count else { throw Failure(description: "stack overflow at pc \(String(format: "%06x", pc))") }
        stack[sp] = UInt8(truncatingIfNeeded: v)
        stack[sp + 1] = UInt8(truncatingIfNeeded: v >> 8)
        stack[sp + 2] = UInt8(truncatingIfNeeded: v >> 16)
        stack[sp + 3] = UInt8(truncatingIfNeeded: v >> 24)
        sp += 4
    }

    func pop() throws -> UInt32 {
        guard sp >= 4 else { throw Failure(description: "stack underflow at pc \(String(format: "%06x", pc))") }
        sp -= 4
        return UInt32(stack[sp]) | UInt32(stack[sp + 1]) << 8 | UInt32(stack[sp + 2]) << 16 | UInt32(stack[sp + 3]) << 24
    }

    func word(_ offset: Int) -> UInt32 {
        UInt32(stack[offset]) | UInt32(stack[offset + 1]) << 8 | UInt32(stack[offset + 2]) << 16 | UInt32(stack[offset + 3]) << 24
    }

    func setWord(_ offset: Int, _ v: UInt32) {
        for i in 0..<4 { stack[offset + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) }
    }

    // MARK: Operands

    private func read(_ o: KCScript.Operand) throws -> UInt32 {
        let base = o.fromStack ? try pop() : o.value
        return o.isMemory ? try load(base, width: o.width) : base
    }

    private func address(_ o: KCScript.Operand) throws -> UInt32 {
        guard o.isMemory else { throw Failure(description: String(format: "operand %02x is not an address at pc %06x", o.mode, pc)) }
        return o.fromStack ? try pop() : o.value
    }

    private static func float(_ v: UInt32) -> Float { Float(bitPattern: v) }
    private static func bits(_ f: Float) -> UInt32 { f.bitPattern }
    private static func int(_ v: UInt32) -> Int32 { Int32(bitPattern: v) }
    private static func word(_ i: Int32) -> UInt32 { UInt32(bitPattern: i) }
    private static func truth(_ b: Bool) -> UInt32 { b ? 1 : 0 }

    /// A binary operation on two values; floats if either operand is a float.
    private static func apply(_ op: KCScript.Opcode, _ a: UInt32, _ b: UInt32, float: Bool) -> UInt32 {
        if float {
            let x = Self.float(a), y = Self.float(b)
            switch op {
            case .add, .addAssign: return bits(x + y)
            case .sub, .subAssign: return bits(x - y)
            case .mul, .mulAssign: return bits(x * y)
            case .div, .divAssign: return y == 0 ? 0 : bits(x / y)
            case .greater: return truth(x > y)
            case .less: return truth(x < y)
            case .greaterEqual: return truth(x >= y)
            case .lessEqual: return truth(x <= y)
            case .equal: return truth(x == y)
            case .notEqual: return truth(x != y)
            case .logicalAnd: return truth(x != 0 && y != 0)
            case .logicalOr: return truth(x != 0 || y != 0)
            default: break
            }
        }
        let x = int(a), y = int(b)
        switch op {
        case .add, .addAssign: return word(x &+ y)
        case .sub, .subAssign: return word(x &- y)
        case .mul, .mulAssign: return word(x &* y)
        case .div, .divAssign: return y == 0 ? 0 : word(x.dividedReportingOverflow(by: y).partialValue)
        case .mod, .modAssign: return y == 0 ? 0 : word(x.remainderReportingOverflow(dividingBy: y).partialValue)
        case .and, .andAssign: return a & b
        case .or, .orAssign: return a | b
        case .xor, .xorAssign: return a ^ b
        case .shl, .shlAssign: return a << (b & 31)
        case .shr, .shrAssign: return word(x >> Int32(b & 31))
        case .logicalAnd: return truth(a != 0 && b != 0)
        case .logicalOr: return truth(a != 0 || b != 0)
        case .greater: return truth(x > y)
        case .less: return truth(x < y)
        case .greaterEqual: return truth(x >= y)
        case .lessEqual: return truth(x <= y)
        case .equal: return truth(a == b)
        case .notEqual: return truth(a != b)
        default: return 0
        }
    }

    // MARK: Executing

    public func step() throws {
        let i = try script.instruction(at: pc)
        steps += 1
        var next = pc + i.size
        let ops = i.operands
        switch i.opcode {
        case .add, .sub, .mul, .div, .mod, .and, .or, .xor, .shl, .shr, .logicalAnd, .logicalOr,
             .greater, .less, .greaterEqual, .lessEqual, .equal, .notEqual:
            let a = try read(ops[0]), b = try read(ops[1])
            try push(Self.apply(i.opcode, a, b, float: ops[0].isFloat || ops[1].isFloat))
        case .bitNot:
            try push(~(try read(ops[0])))
        case .not:
            let v = try read(ops[0])
            try push(Self.truth(ops[0].isFloat ? Self.float(v) == 0 : v == 0))
        case .negate:
            let v = try read(ops[0])
            try push(ops[0].isFloat ? Self.bits(-Self.float(v)) : Self.word(0 &- Self.int(v)))
        case .assign:
            let at = try address(ops[0])
            var v = try read(ops[1])
            if ops[0].isFloat != ops[1].isFloat, !ops[0].isPointer, !ops[1].isPointer {
                v = ops[0].isFloat ? Self.bits(Float(Self.int(v))) : Self.word(Int32(Self.float(v)))
            }
            try store(at, v, width: ops[0].width)
            try push(v)
        case .modAssign, .andAssign, .divAssign, .addAssign, .subAssign, .mulAssign, .xorAssign, .shlAssign,
             .shrAssign, .orAssign:
            let at = try address(ops[0])
            let b = try read(ops[1])
            let a = try load(at, width: ops[0].width)
            let v = Self.apply(i.opcode, a, b, float: ops[0].isFloat || ops[1].isFloat)
            try store(at, v, width: ops[0].width)
            try push(v)
        case .preIncrement, .preDecrement, .postIncrement, .postDecrement:
            let at = try address(ops[0])
            let old = try load(at, width: ops[0].width)
            let up = i.opcode == .preIncrement || i.opcode == .postIncrement
            let new = ops[0].isFloat ? Self.bits(Self.float(old) + (up ? 1 : -1)) : (up ? old &+ 1 : old &- 1)
            try store(at, new, width: ops[0].width)
            try push(i.opcode == .preIncrement || i.opcode == .preDecrement ? new : old)
        case .push, .pushPointer, .pushPointer2:
            try push(try read(ops[0]))
        case .jumpIfZero, .jumpIfNotZero:
            let target = Int(try read(ops[0]))
            let v = try pop()
            if (v == 0) == (i.opcode == .jumpIfZero) { next = target }
        case .jump:
            next = Int(try read(ops[0]))
        case .call:
            let target = Int(try read(ops[0]))
            let argBytes = Int(try read(ops[1]))
            let frame = sp - argBytes
            guard frame >= 0 else { throw Failure(description: String(format: "call at %06x with %d argument bytes", pc, argBytes)) }
            try push(UInt32(next))
            try push(UInt32(fp))
            try push(UInt32(depth))
            fp = frame
            depth += 1
            next = target
        case .ret:
            let returnBytes = Int(try read(ops[0]))
            let result = returnBytes > 0 ? try pop() : 0
            if depth == 0 {
                halted = true
                return
            }
            let header = fp + Int(try read(ops[1]))
            guard header + 12 <= stack.count else { throw Failure(description: "bad frame at \(pc)") }
            next = Int(word(header))
            let callerFrame = Int(word(header + 4))
            depth = Int(word(header + 8))
            sp = fp
            fp = callerFrame
            try push(result)
        case .native:
            let id = Int(try read(ops[0]))
            let argBytes = Int(try read(ops[1]))
            var args: [UInt32] = []
            for _ in 0..<(argBytes / 4) { args.append(try pop()) }
            args.reverse()
            let result = host?.native(id, args, self) ?? 0
            try push(result)
        case .alloc:
            let n = Int(try read(ops[0]))
            guard n >= 0, sp + n <= stack.count else { throw Failure(description: "stack overflow allocating \(n)") }
            for k in sp..<sp + n { stack[k] = 0 }
            sp += n
        case .free:
            sp = max(0, sp - Int(try read(ops[0])))
        case .switchValue:
            let v = try pop()
            var at = next
            var target: Int?
            while let c = try? script.instruction(at: at), c.opcode == .caseValue || c.opcode == .caseRange {
                if target == nil {
                    if c.opcode == .caseValue, c.operands[0].value == v {
                        target = Int(c.operands[1].value)
                    } else if c.opcode == .caseRange,
                              (Self.int(c.operands[0].value)...max(Self.int(c.operands[0].value), Self.int(c.operands[1].value))).contains(Self.int(v)) {
                        target = Int(c.operands[2].value)
                    }
                }
                at += c.size
            }
            next = target ?? at
        case .caseValue, .caseRange:
            break // only reached by falling into a table; `switchValue` reads it
        case .unsignedToFloat:
            try push(Self.bits(Float(try read(ops[0]))))
        case .intToFloat:
            try push(Self.bits(Float(Self.int(try read(ops[0])))))
        case .floatToUnsigned:
            let f = Self.float(try read(ops[0]))
            try push(f.isFinite && f >= 0 && f < 4_294_967_296 ? UInt32(f) : 0)
        case .floatToInt:
            let f = Self.float(try read(ops[0]))
            try push(f.isFinite && abs(f) < 2_147_483_648 ? Self.word(Int32(f)) : 0)
        case .halt:
            halted = true
        case .pop:
            _ = try pop()
        case .addressOfLocal:
            try push(Self.stackBase + UInt32(fp) + (try read(ops[0])))
        case .addressAdd:
            let a = try read(ops[0]), b = try read(ops[1])
            try push(a &+ b)
        }
        pc = next
    }
}
