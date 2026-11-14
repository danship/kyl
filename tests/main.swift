import AppKit

// KYL's tests. scripts/test.sh compiles the app's pure source files together
// with this folder into one program and runs it; the app itself never starts,
// so no menu bar item, web view or window appears while the tests run.

private var checks = 0
private var failures: [String] = []

func expect(_ condition: Bool, _ what: @autoclosure () -> String,
            file: StaticString = #fileID, line: UInt = #line) {
    checks += 1
    if !condition { failures.append("\(file):\(line): \(what())") }
}

func expectEqual<T: Equatable>(_ got: T, _ want: T, _ what: String,
                               file: StaticString = #fileID, line: UInt = #line) {
    expect(got == want, "\(what): expected \(want), got \(got)", file: file, line: line)
}

/// A fraction within a millionth of `want`, for arithmetic on times.
func expectClose(_ got: Double?, _ want: Double, _ what: String,
                 file: StaticString = #fileID, line: UInt = #line) {
    expect(got.map { abs($0 - want) < 1e-6 } ?? false, "\(what): expected \(want), got \(String(describing: got))",
           file: file, line: line)
}

/// A JSON object from text, for feeding the parser recorded answers.
func json(_ text: String) -> [String: Any] {
    guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
          let dictionary = object as? [String: Any] else {
        fatalError("test JSON does not parse: \(text)")
    }
    return dictionary
}

let suites: [(String, () -> Void)] = [
    ("parser", parserTests),
    ("forecaster", forecasterTests),
    ("menu bar title", menuBarTitleTests),
    ("menu bar rings", menuBarRingsTests),
    ("ring image", ringImageTests),
    ("network gate", networkGateTests),
]

for (name, run) in suites {
    let before = failures.count
    run()
    print("\(failures.count == before ? "ok  " : "FAIL") \(name)")
}
for failure in failures { print(failure) }
print("\(checks) checks, \(failures.count) failed")
exit(failures.isEmpty ? 0 : 1)
