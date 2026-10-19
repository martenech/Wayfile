import Foundation
import JavaScriptCore

/// Runs a JavaScript script whose only way out is two native functions: `__call(name, args)` for the
/// Wayfile API and `__log(stream, text)` for output. Used in-process and by the sandboxed
/// `wayfile-script-runner` helper (which forwards `__call` to Wayfile over a pipe).
///
/// Values crossing the bridge are JSON-like: strings, numbers, booleans, arrays, dictionaries, NSNull.
public final class ScriptEngine {
    public enum Outcome {
        /// What the script evaluated to (or its promise resolved to).
        case success(Any?)
        case failure(message: String, line: Int?)
    }

    public typealias Call = (_ name: String, _ args: [Any]) throws -> Any?
    public typealias Log = (_ stream: String, _ text: String) -> Void

    private let js: JSContext

    public init() {
        js = JSContext()!
    }

    private var failure: (String, Int?)?

    /// `context` carries the values of the `wayfile` object plus `functions` / `spaces` / `spaceValues`:
    /// the names of the API functions to expose. Runs the script once and returns what it evaluated to.
    public func run(source: String, sourceURL: URL?, context: [String: Any], call: @escaping Call, log: @escaping Log) -> Outcome {
        load(source: source, sourceURL: sourceURL, context: context, call: call, log: log)
    }

    /// Installs the API and evaluates the script; the context stays alive for `invoke` (plugin panels).
    @discardableResult
    public func load(source: String, sourceURL: URL?, context: [String: Any], call: @escaping Call, log: @escaping Log) -> Outcome {
        failure = nil
        js.exceptionHandler = { [weak self] _, exception in
            if self?.failure == nil { self?.failure = Self.describe(exception) }
        }
        let callBlock: @convention(block) (String, JSValue) -> JSValue? = { [weak js] name, args in
            guard let js else { return nil }
            let list = (args.isArray ? args.toArray() : []) ?? []
            do {
                let result = try call(name, list)
                guard let result else { return JSValue(undefinedIn: js) }
                if result is NSNull { return JSValue(nullIn: js) }
                return JSValue(object: result, in: js)
            } catch {
                js.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: js)
                return nil
            }
        }
        let logBlock: @convention(block) (String, String) -> Void = { stream, text in log(stream, text) }
        js.setObject(callBlock, forKeyedSubscript: "__call" as NSString)
        js.setObject(logBlock, forKeyedSubscript: "__log" as NSString)
        js.evaluateScript(Self.prelude)
        js.objectForKeyedSubscript("__install").call(withArguments: [context])
        // The bridge stays reachable only through `wayfile` and `console`.
        js.evaluateScript("delete globalThis.__install; delete globalThis.__call; delete globalThis.__log;")
        if let failure { return .failure(message: "Internal: " + failure.0, line: nil) }
        return settle(js.evaluateScript(source, withSourceURL: sourceURL))
    }

    /// Calls a global function the script defined (e.g. `render`), after `load`. `values` refreshes
    /// `wayfile.*` (selection, folder…) first.
    public func invoke(_ name: String, args: [Any], values: [String: Any] = [:]) -> Outcome {
        failure = nil
        if let wayfile = js.objectForKeyedSubscript("wayfile"), wayfile.isObject {
            for (key, value) in values { wayfile.setValue(value, forProperty: key) }
            if let panel = wayfile.forProperty("panel"), panel.isObject {
                panel.setValue(values["folder"] ?? NSNull(), forProperty: "path")
                panel.setValue(values["otherFolder"] ?? NSNull(), forProperty: "otherPath")
            }
        }
        guard let function = js.objectForKeyedSubscript(name), !function.isUndefined, function.isObject else {
            return .failure(message: "The script doesn't define \(name)()", line: nil)
        }
        return settle(function.call(withArguments: args.map { JSValue(object: $0, in: js) as Any }))
    }

    /// Waits for a returned promise (API calls are synchronous, so it has settled once JavaScriptCore drains
    /// its job queue after `then` returns) and turns the result into plain values.
    private func settle(_ result: JSValue?) -> Outcome {
        var value = result
        if failure == nil, let promise = value, promise.isObject, promise.hasProperty("then") {
            var settled: JSValue?
            let resolve: @convention(block) (JSValue) -> Void = { settled = $0 }
            let reject: @convention(block) (JSValue) -> Void = { [weak self] in self?.failure = Self.describe($0) }
            promise.invokeMethod("then", withArguments: [unsafeBitCast(resolve, to: AnyObject.self), unsafeBitCast(reject, to: AnyObject.self)])
            value = settled
        }
        if let failure { return .failure(message: failure.0, line: failure.1) }
        guard let value, !value.isUndefined, !value.isNull else { return .success(nil) }
        return .success(value.isArray ? value.toArray() : value.isString ? value.toString() : value.toObject())
    }

    /// Checks syntax without running anything.
    public static func checkSyntax(_ source: String) -> (message: String, line: Int?)? {
        let context = JSContext()!
        var exception: JSValueRef?
        let script = JSStringCreateWithUTF8CString(source)
        defer { JSStringRelease(script) }
        guard !JSCheckScriptSyntax(context.jsGlobalContextRef, script, nil, 1, &exception), let exception else { return nil }
        return describe(JSValue(jsValueRef: exception, in: context))
    }

    /// Message and line of a thrown value (errors carry `line`; thrown strings don't).
    static func describe(_ exception: JSValue?) -> (String, Int?) {
        guard let exception else { return ("JavaScript error", nil) }
        let line = exception.isObject && exception.hasProperty("line") ? Int(exception.forProperty("line").toInt32()) : nil
        return (exception.toString() ?? "JavaScript error", line.flatMap { $0 > 0 ? $0 : nil })
    }

    /// Builds `wayfile` and `console` from the context; every function forwards to `__call`.
    static let prelude = """
    globalThis.__install = function (ctx) {
      const call = __call, log = __log
      const forward = (name) => function (...args) { return call(name, args) }
      const text = (args) => args.map(v => (typeof v === 'object' && v !== null && !(v instanceof Date)) ? JSON.stringify(v) : String(v)).join(' ')
      const wayfile = {}
      for (const [key, value] of Object.entries(ctx.values || {})) wayfile[key] = value
      for (const name of ctx.functions || []) wayfile[name] = forward(name)
      for (const space of new Set([...Object.keys(ctx.spaces || {}), ...Object.keys(ctx.spaceValues || {})])) {
        const object = Object.assign({}, (ctx.spaceValues || {})[space] || {})
        for (const name of (ctx.spaces || {})[space] || []) object[name] = forward(space + '.' + name)
        wayfile[space] = object
      }
      wayfile.log = (...args) => { log('stdout', text(args)) }
      globalThis.wayfile = wayfile
      // Builders for plugin panels: ui.vstack(ui.text('Hi'), ui.button('Go', 'go')) → plain objects Wayfile draws natively.
      const node = (type, props, children) => Object.assign({ type }, props || {}, children ? { children: children.flat(Infinity).filter(c => c) } : {})
      const split = (args) => (args.length && args[0] && typeof args[0] === 'object' && !args[0].type && !Array.isArray(args[0])) ? [args[0], args.slice(1)] : [{}, args]
      const box = (type) => (...args) => { const [props, children] = split(args); return node(type, props, children) }
      globalThis.ui = {
        vstack: box('vstack'), hstack: box('hstack'),
        section: (title, ...args) => { const [props, children] = split(args); return node('section', Object.assign({ title }, props), children) },
        text: (text, props) => node('text', Object.assign({ text: String(text) }, props)),
        heading: (text, props) => node('text', Object.assign({ text: String(text), style: 'headline' }, props)),
        caption: (text, props) => node('text', Object.assign({ text: String(text), style: 'caption' }, props)),
        button: (title, id, props) => node('button', Object.assign({ title, id }, props)),
        textField: (id, props) => node('textField', Object.assign({ id }, props)),
        toggle: (id, title, props) => node('toggle', Object.assign({ id, title }, props)),
        picker: (id, title, options, props) => node('picker', Object.assign({ id, title, options }, props)),
        progress: (value, props) => node('progress', Object.assign({ value }, props)),
        row: (label, value, props) => node('row', Object.assign({ label: String(label), value: String(value) }, props)),
        list: (items, props) => node('list', Object.assign({ items }, props)),
        image: (props) => node('image', props),
        badge: (text, props) => node('badge', Object.assign({ text: String(text) }, props)),
        divider: () => node('divider'),
        spacer: () => node('spacer'),
      }
      globalThis.console = {
        log: wayfile.log, info: wayfile.log,
        warn: (...args) => { log('stderr', text(args)) }, error: (...args) => { log('stderr', text(args)) },
      }
    }
    """
}

// MARK: - Runner protocol

/// Newline-delimited JSON between Wayfile and the runner.
///
///     → {"type":"start","source":…,"url":…,"context":{…}}
///     ← {"type":"call","name":"copy","args":[…]}     → {"type":"result","value":…} | {"type":"error","message":…}
///     ← {"type":"log","stream":"stdout","text":…}
///     ← {"type":"done","value":…} | {"type":"failed","message":…,"line":3}
public enum ScriptWire {
    public static func encode(_ message: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    public static func decode(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed])) as? [String: Any]
    }

    /// Makes a value JSON-safe (dates as ms, data as base64, anything else as text).
    public static func plain(_ value: Any?) -> Any {
        switch value {
        case nil: return NSNull()
        case let dict as [String: Any]: return dict.mapValues { plain($0) }
        case let array as [Any]: return array.map { plain($0) }
        case let number as NSNumber: return number.doubleValue.isFinite ? number : NSNull()
        case let string as String: return string
        case let date as Date: return date.timeIntervalSince1970 * 1000
        case let data as Data: return data.base64EncodedString()
        case is NSNull: return NSNull()
        default: return "\(value!)"
        }
    }
}
