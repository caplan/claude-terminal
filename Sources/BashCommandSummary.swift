import Foundation

/// Condense a shell command to just the command names that would run, keeping
/// the top-level chain operators (`&&`, `||`, `;`). Examples:
///   `gcc -O2 foo.c -o foo` → `gcc`
///   `echo hi && date && uptime && ls -la /x | head -5` → `echo && date && uptime && ls`
///   `bash -c 'make test && git push'` → `make && git push`
/// Left-hand side of a pipe only; env assignments (`FOO=bar cmd`) stripped.
/// Falls back to the original string if parsing produces nothing.
func summarizeBashCommand(_ command: String) -> String {
    let unwrapped = unwrapShellDashC(command) ?? command
    let parts = splitBashTopLevel(unwrapped)
    if parts.isEmpty { return command }
    var out = ""
    for (i, part) in parts.enumerated() {
        if i > 0 { out += " \(part.separator) " }
        out += part.name
    }
    return out.isEmpty ? command : out
}

func splitBashTopLevel(_ s: String) -> [(separator: String, name: String)] {
    var result: [(String, String)] = []
    var buffer = ""
    var sep = ""
    var quote: Character? = nil
    var paren = 0
    let chars = Array(s)
    var i = 0

    func flush() {
        let name = firstBashCommandToken(buffer)
        if !name.isEmpty { result.append((sep, name)) }
        buffer = ""
    }

    while i < chars.count {
        let c = chars[i]
        if let q = quote {
            buffer.append(c)
            if c == q { quote = nil }
            i += 1; continue
        }
        if c == "'" || c == "\"" { quote = c; buffer.append(c); i += 1; continue }
        if c == "(" { paren += 1; buffer.append(c); i += 1; continue }
        if c == ")" { if paren > 0 { paren -= 1 }; buffer.append(c); i += 1; continue }
        if paren == 0 {
            if c == ";" { flush(); sep = ";"; i += 1; continue }
            if (c == "&" || c == "|") && i + 1 < chars.count && chars[i + 1] == c {
                flush(); sep = "\(c)\(c)"; i += 2; continue
            }
        }
        buffer.append(c)
        i += 1
    }
    flush()
    return result
}

func firstBashCommandToken(_ segment: String) -> String {
    var s = segment.trimmingCharacters(in: .whitespaces)
    // Strip leading env assignments: FOO=bar.
    while let m = s.range(of: #"^[A-Za-z_][A-Za-z0-9_]*=\S*\s+"#, options: .regularExpression) {
        s = String(s[m.upperBound...])
    }
    // Keep only the left side of a pipe chain.
    if let pipe = s.firstIndex(of: "|") {
        s = String(s[..<pipe]).trimmingCharacters(in: .whitespaces)
    }
    return s.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
}

func unwrapShellDashC(_ s: String) -> String? {
    let prefixes = ["bash -c ", "sh -c ", "zsh -c ", "/bin/bash -c ", "/bin/sh -c "]
    for p in prefixes where s.hasPrefix(p) {
        var body = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
        if let quote = body.first, quote == "'" || quote == "\"" {
            body = String(body.dropFirst())
            if let end = body.lastIndex(of: quote) {
                body = String(body[..<end])
            }
        }
        return body
    }
    return nil
}
