import Foundation

/// Where FES expressions read and write: `$n` globals, `\n` locals of the running script,
/// `$strN` strings, the system words (`_EXITCODE_`, `_CLICK_L_` …), `@` (the index of the
/// button whose event is running) and macros.
protocol FESContext: AnyObject {
    func global(_ index: Int) -> Int
    func setGlobal(_ index: Int, _ value: Int)
    func local(_ index: Int) -> Int
    func setLocal(_ index: Int, _ value: Int)
    func system(_ name: String) -> Int?
    func macro(_ name: String) -> String?
    /// An object's handle (`btn_sys`, `btn[2]`), compared with `_CLICK_L_`.
    func objectHandle(_ name: String, index: Int?) -> Int?
}

extension FESContext {
    func objectHandle(_ name: String, index: Int?) -> Int? { nil }
}

/// FES integer expressions: C precedence over `|| && | & == != < <= > >= << >> + - * / %`,
/// unary `- !`, parentheses, decimal and `0x` numbers, `$n`, `\n`, `$(expr)`, `\(expr)`, and
/// object names (`btn_sys`, `btn[0]`) as handles.
struct FESExpression {
    private let chars: [Character]
    private var at = 0
    private unowned let context: FESContext

    static func evaluate(_ text: String, _ context: FESContext) -> Int {
        var parser = FESExpression(chars: Array(text), context: context)
        return parser.or()
    }

    private init(chars: [Character], context: FESContext) {
        self.chars = chars
        self.context = context
    }

    private mutating func skip() { while at < chars.count, chars[at] == " " { at += 1 } }

    private mutating func take(_ s: String) -> Bool {
        skip()
        let t = Array(s)
        guard at + t.count <= chars.count, Array(chars[at..<at + t.count]) == t else { return false }
        // `=` must not swallow the first half of `==`, nor `<` of `<=`.
        if t.count == 1, at + 1 < chars.count, "<>=!".contains(t[0]), chars[at + 1] == "=" { return false }
        at += t.count
        return true
    }

    private mutating func or() -> Int {
        var v = and()
        while take("||") { let r = and(); v = (v != 0 || r != 0) ? 1 : 0 }
        return v
    }

    private mutating func and() -> Int {
        var v = bitOr()
        while take("&&") { let r = bitOr(); v = (v != 0 && r != 0) ? 1 : 0 }
        return v
    }

    private mutating func bitOr() -> Int {
        var v = bitAnd()
        while peekSingle("|") { at += 1; v |= bitAnd() }
        return v
    }

    private mutating func bitAnd() -> Int {
        var v = equality()
        while peekSingle("&") { at += 1; v &= equality() }
        return v
    }

    /// `|` or `&` alone (not `||`, `&&`, `|=`).
    private mutating func peekSingle(_ c: Character) -> Bool {
        skip()
        guard at < chars.count, chars[at] == c else { return false }
        return at + 1 >= chars.count || (chars[at + 1] != c && chars[at + 1] != "=")
    }

    private mutating func equality() -> Int {
        var v = relation()
        while true {
            if take("==") { v = v == relation() ? 1 : 0 } else if take("!=") { v = v != relation() ? 1 : 0 } else { return v }
        }
    }

    private mutating func relation() -> Int {
        var v = shift()
        while true {
            if take("<=") { v = v <= shift() ? 1 : 0 } else if take(">=") { v = v >= shift() ? 1 : 0 }
            else if take("<<") || take(">>") { at -= 2; return v }
            else if take("<") { v = v < shift() ? 1 : 0 } else if take(">") { v = v > shift() ? 1 : 0 } else { return v }
        }
    }

    private mutating func shift() -> Int {
        var v = sum()
        while true {
            if take("<<") { v = v << max(0, min(63, sum())) } else if take(">>") { v = v >> max(0, min(63, sum())) } else { return v }
        }
    }

    private mutating func sum() -> Int {
        var v = product()
        while true {
            if take("+") { v &+= product() } else if take("-") { v &-= product() } else { return v }
        }
    }

    private mutating func product() -> Int {
        var v = unary()
        while true {
            if take("*") { v &*= unary() }
            else if take("/") { let r = unary(); v = r == 0 ? 0 : v / r }
            else if take("%") { let r = unary(); v = r == 0 ? 0 : v % r }
            else { return v }
        }
    }

    private mutating func unary() -> Int {
        if take("-") { return 0 &- unary() }
        if take("!") { return unary() == 0 ? 1 : 0 }
        return primary()
    }

    private mutating func primary() -> Int {
        skip()
        guard at < chars.count else { return 0 }
        let c = chars[at]
        if c == "(" {
            at += 1
            let v = or()
            _ = take(")")
            return v
        }
        if c == "$" || c == "\\" {
            at += 1
            let index: Int
            if at < chars.count, chars[at] == "(" {
                at += 1
                index = or()
                _ = take(")")
            } else {
                index = number() ?? 0
            }
            return c == "$" ? context.global(index) : context.local(index)
        }
        if c == "@" {
            at += 1
            return context.system("@") ?? 0
        }
        if let n = number() { return n }
        // A word: a system variable or a macro.
        var word = ""
        while at < chars.count, chars[at].isLetter || chars[at].isNumber || chars[at] == "_" {
            word.append(chars[at])
            at += 1
        }
        if let v = context.system(word) { return v }
        if let m = context.macro(word) { return FESExpression.evaluate(m, context) }
        var index: Int?
        if at < chars.count, chars[at] == "[" {
            at += 1
            index = or()
            _ = take("]")
        }
        if let handle = context.objectHandle(word, index: index) { return handle }
        return 0
    }

    private mutating func number() -> Int? {
        skip()
        guard at < chars.count, chars[at].isNumber else { return nil }
        if chars[at] == "0", at + 1 < chars.count, chars[at + 1] == "x" || chars[at + 1] == "X" {
            at += 2
            var hex = ""
            while at < chars.count, chars[at].isHexDigit { hex.append(chars[at]); at += 1 }
            return Int(UInt32(hex, radix: 16) ?? 0)
        }
        var digits = ""
        while at < chars.count, chars[at].isNumber { digits.append(chars[at]); at += 1 }
        return Int(digits)
    }
}
