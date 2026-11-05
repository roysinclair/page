import XCTest
@testable import PageCore

/// Page builds AppleScript source as a string and runs it in-process with
/// `NSAppleScript` (SonarCloud swift:S1523). That is safe only while every
/// value that reaches the source (a tty, window text, a menu digit, a user
/// name) goes through `ProcessRunner.appleScriptQuote` and nowhere else.
///
/// These tests never run AppleScript. They feed hostile values through the
/// escaper and through every script builder, then lex the result the way
/// AppleScript does (a string literal ends at the first `"` that is not
/// preceded by an odd run of backslashes) and check two things:
///   1. the value decodes back to itself inside one literal, and
///   2. the program text outside the literals is identical whatever the
///      value is, so the value can never add or change a statement.
final class AppleScriptInjectionTests: XCTestCase {
    /// Quotes, backslashes, newlines, tabs, shell-script breakouts, unicode.
    static let hostile: [String] = [
        "plain",
        "",
        "a\"b",
        "\"",
        "\\",
        "\\\\",
        "\\\"",
        "ends with a backslash\\",
        "a\\nb",                       // backslash then n, which AppleScript would read as a newline
        "line one\nline two",
        "cr\rlf\r\nend",
        "tab\there",
        "\"& do shell script \"x\"",
        "x\" & do shell script \"touch /tmp/pwned\" & \"",
        "\"\nend tell\ndo shell script \"x\"\ntell application \"Terminal\"\n\"",
        "\\\" & (do shell script \"x\") & \"",
        "/dev/ttys003\" then\ndo shell script \"x\"\nend if\nif \"a\" is \"a",
        "日本語 😀 é ñ \u{200B}",
        "\u{2028}\u{2029}\u{0085}",
        "nul\u{0}byte",
        "'single' `back` $(sub) ${var}",
    ]

    // MARK: a minimal AppleScript string-literal lexer

    /// The unescaped contents of the literal that opens at `chars[start]`
    /// (which must be `"`), and the index just past its closing quote.
    /// nil when the literal never closes or uses an escape other than `\\` or `\"`.
    private func readLiteral(_ chars: [Character], from start: Int) -> (value: String, end: Int)? {
        XCTAssertEqual(chars[start], "\"")
        var out = ""
        var i = start + 1
        while i < chars.count {
            let c = chars[i]
            if c == "\\" {
                guard i + 1 < chars.count, chars[i + 1] == "\\" || chars[i + 1] == "\"" else { return nil }
                out.append(chars[i + 1])
                i += 2
            } else if c == "\"" {
                return (out, i + 1)
            } else {
                out.append(c)
                i += 1
            }
        }
        return nil
    }

    /// `source` with every string literal replaced by `""`, plus the decoded
    /// literals. nil if a literal is unterminated or malformed.
    private func lex(_ source: String) -> (skeleton: String, literals: [String])? {
        let chars = Array(source)
        var skeleton = ""
        var literals: [String] = []
        var i = 0
        while i < chars.count {
            if chars[i] == "\"" {
                guard let lit = readLiteral(chars, from: i) else { return nil }
                literals.append(lit.value)
                skeleton += "\"\""
                i = lit.end
            } else {
                skeleton.append(chars[i])
                i += 1
            }
        }
        return (skeleton, literals)
    }

    // MARK: the escaper

    func testQuoteProducesExactlyOneLiteralThatDecodesToTheInput() {
        for payload in Self.hostile {
            let quoted = ProcessRunner.appleScriptQuote(payload)
            let chars = Array(quoted)
            guard let lit = readLiteral(chars, from: 0) else {
                XCTFail("not a well-formed literal: \(payload.debugDescription)"); continue
            }
            XCTAssertEqual(lit.end, chars.count, "the literal must end at the last character: \(payload.debugDescription)")
            XCTAssertEqual(lit.value, payload, "round trip: \(payload.debugDescription)")
        }
    }

    func testQuoteLeavesNoBareQuoteAndNoUnpairedBackslash() {
        for payload in Self.hostile {
            let inner = Array(ProcessRunner.appleScriptQuote(payload)).dropFirst().dropLast()
            var i = inner.startIndex
            while i < inner.endIndex {
                let c = inner[i]
                XCTAssertNotEqual(c, "\"" , "bare quote in \(payload.debugDescription)")
                if c == "\\" {
                    let next = inner.index(after: i)
                    XCTAssertTrue(next < inner.endIndex && (inner[next] == "\\" || inner[next] == "\""),
                                  "backslash must escape a backslash or a quote: \(payload.debugDescription)")
                    i = inner.index(after: next)
                } else {
                    i = inner.index(after: i)
                }
            }
        }
    }

    func testQuoteKeepsTheBreakoutPayloadInsideTheLiteral() {
        let payload = "\"& do shell script \"x\""
        let source = "set v to \(ProcessRunner.appleScriptQuote(payload))\nreturn v"
        let lexed = try! XCTUnwrap(lex(source))
        XCTAssertEqual(lexed.literals, [payload])
        XCTAssertEqual(lexed.skeleton, "set v to \"\"\nreturn v")
        XCTAssertFalse(lexed.skeleton.contains("shell"))
    }

    func testQuoteDoesNotChangeOrdinaryInput() {
        XCTAssertEqual(ProcessRunner.appleScriptQuote("/dev/ttys003"), "\"/dev/ttys003\"")
        XCTAssertEqual(ProcessRunner.appleScriptQuote("hello world 5"), "\"hello world 5\"")
        XCTAssertEqual(ProcessRunner.appleScriptQuote("日本語 😀"), "\"日本語 😀\"")
        XCTAssertEqual(ProcessRunner.appleScriptQuote("a\nb\tc"), "\"a\nb\tc\"")
    }

    // MARK: every script builder

    /// Each builder takes one hostile value. A value must only ever appear as
    /// the contents of a string literal, so the text outside literals matches
    /// the text produced for a harmless value.
    private func assertValueOnlyEntersAsALiteral(_ name: String, literal: (String) -> String = { $0 },
                                                 _ build: (String) -> String,
                                                 file: StaticString = #filePath, line: UInt = #line) {
        guard let baseline = lex(build("harmless")) else {
            return XCTFail("\(name): baseline script does not lex", file: file, line: line)
        }
        for payload in Self.hostile {
            let script = build(payload)
            guard let lexed = lex(script) else {
                XCTFail("\(name): payload broke the string literals: \(payload.debugDescription)", file: file, line: line)
                continue
            }
            XCTAssertEqual(lexed.skeleton, baseline.skeleton,
                           "\(name): payload changed the program text outside literals: \(payload.debugDescription)", file: file, line: line)
            XCTAssertEqual(lexed.literals.count, baseline.literals.count,
                           "\(name): payload added or removed a literal: \(payload.debugDescription)", file: file, line: line)
            XCTAssertTrue(lexed.literals.contains(literal(payload)),
                          "\(name): payload is not carried verbatim in a literal: \(payload.debugDescription)", file: file, line: line)
            // Also a plain substring check against the escaper.
            XCTAssertTrue(script.contains(ProcessRunner.appleScriptQuote(literal(payload))), name, file: file, line: line)
        }
    }

    func testTerminalFocusScriptsQuoteTheTTY() {
        assertValueOnlyEntersAsALiteral("TerminalFocus.terminalScript") { TerminalFocus.terminalScript(tty: $0) }
        assertValueOnlyEntersAsALiteral("TerminalFocus.iTermScript") { TerminalFocus.iTermScript(tty: $0) }
    }

    func testCodexTerminalScriptsQuoteTheTTYAndTheText() {
        assertValueOnlyEntersAsALiteral("CodexInjector.terminalTypeScript(devTTY)") {
            CodexInjector.terminalTypeScript(devTTY: $0, text: "hello")
        }
        assertValueOnlyEntersAsALiteral("CodexInjector.terminalTypeScript(text)") {
            CodexInjector.terminalTypeScript(devTTY: "/dev/ttys003", text: $0)
        }
        assertValueOnlyEntersAsALiteral("CodexInjector.terminalEnterScript") {
            CodexInjector.terminalEnterScript(devTTY: $0)
        }
    }

    func testInjectionExecutorTerminalScriptsQuoteTheTTYAndTheTypedText() {
        assertValueOnlyEntersAsALiteral("terminalCommandScript(tty)") {
            InjectionExecutor.terminalCommandScript(tty: $0, body: "return \"ok:\" & (contents of t)")
        }
        assertValueOnlyEntersAsALiteral("terminalCommandScript(body text)") {
            InjectionExecutor.terminalCommandScript(tty: "/dev/ttys003", body: InjectionExecutor.terminalDoScriptBody($0))
        }
        assertValueOnlyEntersAsALiteral("terminalDoScriptBody") { InjectionExecutor.terminalDoScriptBody($0) }
    }

    func testInjectionExecutorITermScriptsQuoteTheTTYAndTheTypedText() {
        assertValueOnlyEntersAsALiteral("iTermWriteScript(tty)") {
            InjectionExecutor.iTermWriteScript(tty: $0, payload: ProcessRunner.appleScriptQuote("hi"))
        }
        assertValueOnlyEntersAsALiteral("iTermWriteScript(text)") {
            InjectionExecutor.iTermWriteScript(tty: "/dev/ttys003", payload: ProcessRunner.appleScriptQuote($0))
        }
        assertValueOnlyEntersAsALiteral("iTermWriteScript(key)", literal: { "[" + $0 }) {
            // The shape used for arrow keys: ESC then the CSI tail.
            InjectionExecutor.iTermWriteScript(tty: "/dev/ttys003",
                                               payload: "((character id 27) & \(ProcessRunner.appleScriptQuote("[" + $0)))")
        }
        assertValueOnlyEntersAsALiteral("iTermContentsScript") { InjectionExecutor.iTermContentsScript(tty: $0) }
    }

    func testPowerHelperScriptQuotesTheUserNameAndPrompt() {
        // The user name sits inside a larger shell script that is itself one
        // literal (and this script runs through /usr/bin/osascript, not NSAppleScript).
        let baseline = try! XCTUnwrap(lex(PowerHelperInstaller.appleScript(user: "harmless")))
        for payload in Self.hostile {
            guard let lexed = lex(PowerHelperInstaller.appleScript(user: payload)) else {
                XCTFail("user name broke the literals: \(payload.debugDescription)"); continue
            }
            XCTAssertEqual(lexed.skeleton, baseline.skeleton, payload.debugDescription)
            XCTAssertEqual(lexed.literals.count, 2, payload.debugDescription)
        }
    }

    // MARK: behaviour for valid input is unchanged

    func testTerminalDoScriptBodyForAMenuDigitMatchesTheOldInlineForm() {
        // This used to be "do script \"\(digit)\" in t\nreturn \"ok\"" with the digit unescaped.
        for digit in "23456789" {
            XCTAssertEqual(InjectionExecutor.terminalDoScriptBody(String(digit)),
                           "do script \"\(digit)\" in t\nreturn \"ok\"")
        }
    }

    func testTerminalDoScriptBodyForTextMatchesTheOldInlineForm() {
        let text = "yes please"
        XCTAssertEqual(InjectionExecutor.terminalDoScriptBody(text),
                       "do script \(ProcessRunner.appleScriptQuote(text)) in t\nreturn \"ok\"")
    }

    func testTheOnlyScriptSourcesAreTheBuildersTestedAbove() throws {
        // A tripwire: if a new NSAppleScript caller appears it must be added
        // to this file, so a new interpolation cannot slip in unreviewed.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PageCore")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw XCTSkip("sources not available")
        }
        var users: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if text.contains("NSAppleScript(source:") { users.append(url.lastPathComponent) }
        }
        XCTAssertEqual(users.sorted(), ["CodexInjector.swift", "InjectionExecutor.swift"])
    }
}
