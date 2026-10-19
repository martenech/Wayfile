import Foundation
import JavaScriptCore
#if canImport(ScriptBridge)
import ScriptBridge
#endif

// wayfile-script-runner: runs one JavaScript script for Wayfile inside a sandbox that allows no
// file, network or process access ("pure-computation"). Everything the script does goes through API calls
// sent back to Wayfile over stdout / stdin, where permissions are checked and changes recorded.

@_silgen_name("sandbox_init")
private func sandbox_init(_ profile: UnsafePointer<CChar>, _ flags: UInt64, _ errorbuf: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

private let output = FileHandle.standardOutput

private func send(_ message: [String: Any]) {
    output.write(ScriptWire.encode(message))
}

private func receive() -> [String: Any]? {
    guard let line = readLine(strippingNewline: true) else { return nil }
    return ScriptWire.decode(Data(line.utf8))
}

struct RunnerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

guard let start = receive(), start["type"] as? String == "start", let source = start["source"] as? String else {
    FileHandle.standardError.write("wayfile-script-runner: expected a start message\n".data(using: .utf8)!)
    exit(2)
}

// JavaScriptCore is loaded before the sandbox closes the door on the file system.
let engine = ScriptEngine()
if ProcessInfo.processInfo.environment["WAYFILE_RUNNER_NO_SANDBOX"] == nil {
    var error: UnsafeMutablePointer<CChar>?
    guard sandbox_init("pure-computation", 1, &error) == 0 else {
        send(["type": "failed", "message": "Couldn't enter the script sandbox: " + (error.map { String(cString: $0) } ?? "unknown error")])
        exit(3)
    }
}

let url = (start["url"] as? String).map { URL(fileURLWithPath: $0) }
let call: ScriptEngine.Call = { name, args in
    send(["type": "call", "name": name, "args": args.map { ScriptWire.plain($0) }])
    guard let reply = receive() else { exit(0) } // Wayfile went away (or stopped the script)
    if reply["type"] as? String == "error" { throw RunnerError(message: reply["message"] as? String ?? "Error") }
    return reply["value"]
}
let log: ScriptEngine.Log = { stream, text in send(["type": "log", "stream": stream, "text": text]) }

func report(_ outcome: ScriptEngine.Outcome) {
    switch outcome {
    case .success(let value):
        send(["type": "done", "value": ScriptWire.plain(value)])
    case .failure(let message, let line):
        var failed: [String: Any] = ["type": "failed", "message": message]
        if let line { failed["line"] = line }
        send(failed)
    }
}

report(engine.load(source: source, sourceURL: url, context: start["context"] as? [String: Any] ?? [:], call: call, log: log))

// Plugin panels keep the script alive: each invoke calls one of its functions (render, action…).
if start["session"] as? Bool == true {
    while let message = receive(), message["type"] as? String == "invoke", let function = message["function"] as? String {
        report(engine.invoke(function, args: message["args"] as? [Any] ?? [], values: message["values"] as? [String: Any] ?? [:]))
    }
}
