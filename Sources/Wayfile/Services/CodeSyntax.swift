import Foundation

// MARK: - Highlighting

/// A small tokenizer for script highlighting: comments, strings, numbers, keywords, API names and
/// `@key` header annotations. Ranges are UTF-16 (NSString) ranges.
enum SyntaxHighlighter {
    enum Kind: Hashable { case comment, string, number, keyword, api, annotation }

    struct Token: Hashable {
        let range: NSRange
        let kind: Kind
    }

    static func keywords(_ language: Script.Language) -> Set<String> {
        switch language {
        case .javascript:
            return ["const", "let", "var", "function", "return", "if", "else", "for", "of", "in", "while", "do", "break", "continue",
                    "switch", "case", "default", "try", "catch", "finally", "throw", "new", "typeof", "instanceof", "async", "await",
                    "true", "false", "null", "undefined", "class", "this", "delete", "void", "yield"]
        case .sh, .zsh, .bash:
            return ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac", "function",
                    "return", "local", "export", "set", "exit", "echo", "read", "shift", "true", "false"]
        case .python:
            return ["def", "return", "if", "elif", "else", "for", "in", "while", "break", "continue", "import", "from", "as", "with",
                    "try", "except", "finally", "raise", "class", "lambda", "pass", "and", "or", "not", "is", "None", "True", "False",
                    "yield", "global", "nonlocal", "async", "await"]
        case .applescript:
            return ["tell", "end", "on", "run", "set", "to", "repeat", "with", "if", "then", "else", "return", "of", "in", "as",
                    "try", "error", "true", "false", "application", "log", "display", "dialog", "every", "item", "my"]
        case .pipeline:
            return ["shortcut"]
        }
    }

    /// Names highlighted as the app's API.
    static func apiRoots(_ language: Script.Language) -> Set<String> {
        switch language {
        case .javascript: return ["wayfile", "console"]
        case .python: return ["os", "sys"]
        default: return []
        }
    }

    static func tokens(_ text: String, language: Script.Language) -> [Token] {
        let s = text as NSString
        let n = s.length
        let keywords = keywords(language)
        let apiRoots = apiRoots(language)
        var tokens: [Token] = []
        var i = 0

        func char(_ index: Int) -> unichar { index < n ? s.character(at: index) : 0 }
        func isIdentStart(_ c: unichar) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 }
        func isIdentPart(_ c: unichar) -> Bool { isIdentStart(c) || (c >= 48 && c <= 57) }
        func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }
        func has(_ literal: String, at index: Int) -> Bool {
            let length = (literal as NSString).length
            return index + length <= n && s.substring(with: NSRange(location: index, length: length)) == literal
        }
        func lineEnd(_ from: Int) -> Int {
            var j = from
            while j < n && char(j) != 10 { j += 1 }
            return j
        }
        /// A comment, with `@key` annotations inside it.
        func comment(_ start: Int, _ end: Int) {
            tokens.append(Token(range: NSRange(location: start, length: end - start), kind: .comment))
            let body = s.substring(with: NSRange(location: start, length: end - start)) as NSString
            let at = body.range(of: "@")
            guard at.location != NSNotFound else { return }
            var j = at.location + 1
            while j < body.length, isIdentPart(body.character(at: j)) { j += 1 }
            if j > at.location + 1 { tokens.append(Token(range: NSRange(location: start + at.location, length: j - at.location), kind: .annotation)) }
        }

        let lineComment: [String]
        switch language {
        case .javascript: lineComment = ["//"]
        case .applescript: lineComment = ["--"]
        default: lineComment = ["#"]
        }

        while i < n {
            let c = char(i)
            // Line comments ("#" in shell only at a word start: $# and ${#x} aren't comments).
            if let marker = lineComment.first(where: { has($0, at: i) }),
               marker != "#" || i == 0 || [32, 9, 10, 59].contains(char(i - 1)) {
                let end = lineEnd(i)
                comment(i, end)
                i = end
                continue
            }
            // Block comments
            if language == .javascript && has("/*", at: i) {
                let rest = s.range(of: "*/", options: [], range: NSRange(location: i + 2, length: n - i - 2))
                let end = rest.location == NSNotFound ? n : NSMaxRange(rest)
                comment(i, end)
                i = end
                continue
            }
            if language == .applescript && has("(*", at: i) {
                let rest = s.range(of: "*)", options: [], range: NSRange(location: i + 2, length: n - i - 2))
                let end = rest.location == NSNotFound ? n : NSMaxRange(rest)
                comment(i, end)
                i = end
                continue
            }
            // Python triple-quoted strings
            if language == .python && (has("\"\"\"", at: i) || has("'''", at: i)) {
                let quote = s.substring(with: NSRange(location: i, length: 3))
                let rest = s.range(of: quote, options: [], range: NSRange(location: i + 3, length: n - i - 3))
                let end = rest.location == NSNotFound ? n : NSMaxRange(rest)
                tokens.append(Token(range: NSRange(location: i, length: end - i), kind: .string))
                i = end
                continue
            }
            // Strings: ' " and ` (JavaScript); backslash escapes except in shell single quotes; AppleScript only uses "
            let quotes: [unichar] = language == .javascript ? [34, 39, 96] : language == .applescript ? [34] : [34, 39]
            if quotes.contains(c) {
                var j = i + 1
                let escapes = !(c == 39 && [.sh, .zsh, .bash].contains(language))
                while j < n && char(j) != c {
                    if escapes && char(j) == 92 { j += 1 }
                    // Only template literals and shell strings span lines.
                    if char(j) == 10 && c != 96 && ![.sh, .zsh, .bash].contains(language) { break }
                    j += 1
                }
                let end = min(j + 1, n)
                tokens.append(Token(range: NSRange(location: i, length: end - i), kind: .string))
                i = end
                continue
            }
            // Shell variables
            if [.sh, .zsh, .bash].contains(language) && c == 36 {
                var j = i + 1
                if char(j) == 123 {
                    while j < n && char(j) != 125 && char(j) != 10 { j += 1 }
                    j = min(j + 1, n)
                } else if isIdentStart(char(j)) {
                    while j < n && isIdentPart(char(j)) { j += 1 }
                } else if j < n && (isDigit(char(j)) || [35, 64, 42, 63].contains(char(j))) {
                    j += 1
                }
                if j > i + 1 {
                    tokens.append(Token(range: NSRange(location: i, length: j - i), kind: .api))
                    i = j
                    continue
                }
            }
            // Numbers
            if isDigit(c) && (i == 0 || !isIdentPart(char(i - 1))) {
                var j = i
                while j < n && (isDigit(char(j)) || char(j) == 46 || char(j) == 95 || char(j) == 120 || (char(j) >= 97 && char(j) <= 102)) { j += 1 }
                tokens.append(Token(range: NSRange(location: i, length: j - i), kind: .number))
                i = j
                continue
            }
            // Identifiers: keywords, and API chains like wayfile.dialogs.confirm
            if isIdentStart(c) && c != 36 || (c == 36 && language == .javascript) {
                var j = i
                while j < n && isIdentPart(char(j)) { j += 1 }
                let word = s.substring(with: NSRange(location: i, length: j - i))
                if apiRoots.contains(word) {
                    while char(j) == 46 && isIdentStart(char(j + 1)) {
                        j += 1
                        while j < n && isIdentPart(char(j)) { j += 1 }
                    }
                    tokens.append(Token(range: NSRange(location: i, length: j - i), kind: .api))
                } else if keywords.contains(word) && (i == 0 || char(i - 1) != 46) {
                    tokens.append(Token(range: NSRange(location: i, length: j - i), kind: .keyword))
                }
                i = j
                continue
            }
            i += 1
        }
        return tokens
    }
}

// MARK: - Indentation

enum CodeIndent {
    /// One level of indentation for the language.
    static func unit(_ language: Script.Language) -> String {
        switch language {
        case .python: return "    "
        case .applescript: return "\t"
        default: return "  "
        }
    }

    /// The indentation for a new line after `line` (the text before the cursor on that line).
    static func indent(after line: String, language: Script.Language) -> String {
        let leading = String(line.prefix { $0 == " " || $0 == "\t" })
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var deeper = false
        switch language {
        case .javascript:
            deeper = ["{", "[", "("].contains(trimmed.last ?? " ")
        case .python:
            deeper = trimmed.hasSuffix(":") && !trimmed.hasPrefix("#")
        case .sh, .zsh, .bash:
            deeper = ["then", "do", "{", "else", " in"].contains { trimmed.hasSuffix($0) }
        case .applescript:
            let first = trimmed.split(separator: " ").first.map(String.init) ?? ""
            deeper = ["tell", "on", "repeat", "if", "try"].contains(first) && !trimmed.hasPrefix("end") && !(first == "if" && !trimmed.hasSuffix("then"))
        case .pipeline:
            deeper = false
        }
        return leading + (deeper ? unit(language) : "")
    }

    /// Typing one of these first on a line moves it out one level.
    static func dedentTriggers(_ language: Script.Language) -> Set<String> {
        switch language {
        case .javascript: return ["}", "]", ")"]
        case .sh, .zsh, .bash: return ["}"]
        default: return []
        }
    }
}

// MARK: - Syntax check

/// Syntax checks that don't run the script: JavaScriptCore for JavaScript, `-n` for shells,
/// Python's `ast` for Python. Returns a message and line, or nil when it parses.
enum ScriptLinter {
    struct Problem: Equatable, Sendable {
        let message: String
        let line: Int?
    }

    static func check(_ source: String, language: Script.Language) async -> Problem? {
        switch language {
        case .javascript:
            return JSScriptHost.checkSyntax(source).map { Problem(message: $0.message, line: $0.line) }
        case .sh, .zsh, .bash:
            let shell = language == .sh ? "/bin/sh" : "/bin/\(language.rawValue)"
            let output = await Shell.run(shell, ["-n", "-c", source])
            return output.status == 0 ? nil : parse(output.stderr, language: language)
        case .python:
            let code = "import ast,sys\ntry:\n ast.parse(sys.argv[1])\nexcept SyntaxError as e:\n print(f'{e.lineno}:{e.msg}'); sys.exit(1)"
            let output = await Shell.run("/usr/bin/env", ["python3", "-c", code, source])
            return output.status == 0 ? nil : parse(output.stdout + output.stderr, language: language)
        case .applescript, .pipeline:
            return nil
        }
    }

    /// Picks the line number out of the checker's message.
    static func parse(_ output: String, language: Script.Language) -> Problem? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let first = text.split(separator: "\n").first.map(String.init) ?? text
        let patterns: [String]
        switch language {
        case .python: patterns = [#"^(\d+):(.*)$"#]
        // bash: "bash: -c: line 3: syntax error…"   zsh / sh: "zsh:3: parse error…"
        default: patterns = [#"line (\d+): (.*)$"#, #"^[^:]*:(\d+): (.*)$"#]
        }
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)),
                  let lineRange = Range(match.range(at: 1), in: first), let messageRange = Range(match.range(at: 2), in: first) else { continue }
            return Problem(message: first[messageRange].trimmingCharacters(in: .whitespaces), line: Int(first[lineRange]))
        }
        return Problem(message: first, line: nil)
    }

    /// "Line 3: …" at the start of a console line (how runtime errors are reported).
    static func line(fromConsole text: String) -> Int? {
        guard text.hasPrefix("Line ") else { return nil }
        return Int(text.dropFirst(5).prefix { $0.isNumber })
    }
}
