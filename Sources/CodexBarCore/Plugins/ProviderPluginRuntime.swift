#if canImport(JavaScriptCore)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@preconcurrency import JavaScriptCore

public final class ProviderPluginRuntime: @unchecked Sendable {
    public static let defaultTimeout: TimeInterval = 20
    public static let maximumResponseBytes = 5 * 1024 * 1024

    public let manifest: ProviderPluginManifest

    private let source: String
    private let preludeSource: String
    private let transport: any ProviderHTTPTransport
    private let timeout: TimeInterval
    private let responseSizeLimit: Int
    private let lock = NSLock()
    private var worker: ProviderPluginWorker?

    public convenience init(
        bundledPlugin name: String,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        timeout: TimeInterval = ProviderPluginRuntime.defaultTimeout) throws
    {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js") else {
            throw ProviderPluginError.load("bundled plugin '\(name).js' was not found")
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        try self.init(source: source, transport: transport, timeout: timeout)
    }

    public init(
        source: String,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        timeout: TimeInterval = ProviderPluginRuntime.defaultTimeout,
        responseSizeLimit: Int = ProviderPluginRuntime.maximumResponseBytes) throws
    {
        guard timeout > 0 else { throw ProviderPluginError.load("timeout must be positive") }
        guard responseSizeLimit > 0 else { throw ProviderPluginError.load("response size limit must be positive") }
        guard let preludeURL = Bundle.module.url(
            forResource: "provider-plugin-prelude",
            withExtension: "js")
        else {
            throw ProviderPluginError.load("provider plugin prelude was not found")
        }

        self.source = source
        self.preludeSource = try String(contentsOf: preludeURL, encoding: .utf8)
        self.transport = transport
        self.timeout = timeout
        self.responseSizeLimit = responseSizeLimit

        let worker = try ProviderPluginWorker.make(
            source: source,
            preludeSource: self.preludeSource,
            transport: transport,
            responseSizeLimit: responseSizeLimit)
        self.worker = worker
        self.manifest = worker.manifest
    }

    public func fetchUsage(secrets: [String: String], now: Date = Date()) async throws -> UsageSnapshot {
        let sanitizedSecrets = secrets.mapValues {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let authSecret = sanitizedSecrets[self.manifest.auth.secret], !authSecret.isEmpty else {
            throw ProviderPluginError.secretAccess("required secret '\(self.manifest.auth.secret)' is unavailable")
        }

        let worker = try self.currentWorker()
        let gate = ProviderPluginCompletionGate<UsageSnapshot>()
        return try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)
            worker.fetch(secrets: sanitizedSecrets, now: now) { result in
                gate.finish(result.mapError { self.redactedError($0, secrets: sanitizedSecrets.values) })
            }
            Task.detached { [weak self, weak worker] in
                guard let self, let worker else { return }
                let nanoseconds = UInt64(self.timeout * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                if gate.finish(.failure(ProviderPluginError.timedOut)) {
                    self.discard(worker)
                }
            }
        }
    }

    public func globalType(of name: String) throws -> String {
        try self.currentWorker().globalType(of: name)
    }

    private func currentWorker() throws -> ProviderPluginWorker {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let worker = self.worker {
            return worker
        }
        let worker = try ProviderPluginWorker.make(
            source: self.source,
            preludeSource: self.preludeSource,
            transport: self.transport,
            responseSizeLimit: self.responseSizeLimit)
        guard worker.manifest.id == self.manifest.id else {
            throw ProviderPluginError.load("reloaded plugin changed provider id")
        }
        self.worker = worker
        return worker
    }

    private func discard(_ worker: ProviderPluginWorker) {
        self.lock.lock()
        if self.worker === worker {
            self.worker = nil
        }
        self.lock.unlock()
    }

    private func redactedError(_ error: Error, secrets: Dictionary<String, String>.Values) -> Error {
        var message = error.localizedDescription
        for secret in secrets where !secret.isEmpty {
            message = message.replacingOccurrences(of: secret, with: "<redacted>")
        }
        if let pluginError = error as? ProviderPluginError {
            switch pluginError {
            case .timedOut: return pluginError
            case .load: return ProviderPluginError.load(message.removingPluginErrorPrefix)
            case .invalidManifest: return ProviderPluginError.invalidManifest(message.removingPluginErrorPrefix)
            case .networkPolicy: return ProviderPluginError.networkPolicy(message.removingPluginErrorPrefix)
            case .http: return ProviderPluginError.http(message.removingPluginErrorPrefix)
            case .secretAccess: return ProviderPluginError.secretAccess(message.removingPluginErrorPrefix)
            case .invalidSnapshot: return ProviderPluginError.invalidSnapshot(message.removingPluginErrorPrefix)
            case .script: return ProviderPluginError.script(message.removingPluginErrorPrefix)
            }
        }
        return ProviderPluginError.script(message)
    }
}

extension String {
    fileprivate var removingPluginErrorPrefix: String {
        guard let separator = self.firstIndex(of: ":") else { return self }
        return String(self[self.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
    }
}

private final class ProviderPluginCompletionGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        self.lock.lock()
        if let result = self.pendingResult {
            self.pendingResult = nil
            self.lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        self.lock.unlock()
    }

    @discardableResult
    func finish(_ result: Result<Value, Error>) -> Bool {
        self.lock.lock()
        guard !self.finished else {
            self.lock.unlock()
            return false
        }
        self.finished = true
        guard let continuation = self.continuation else {
            self.pendingResult = result
            self.lock.unlock()
            return true
        }
        self.continuation = nil
        self.lock.unlock()
        continuation.resume(with: result)
        return true
    }
}

private final class ProviderPluginJSValueBox: @unchecked Sendable {
    let value: JSValue

    init(_ value: JSValue) {
        self.value = value
    }
}

private final class ProviderPluginObjectBox: @unchecked Sendable {
    let value: [String: Any]

    init(_ value: [String: Any]) {
        self.value = value
    }
}

private struct ProviderPluginHTTPRequestCallbacks: @unchecked Sendable {
    let wantsJSON: Bool
    let resolve: ProviderPluginJSValueBox
    let reject: ProviderPluginJSValueBox
}

private final class ProviderPluginWorker: @unchecked Sendable {
    private typealias HTTPBlock = @convention(block) (String, JSValue, Bool, JSValue, JSValue) -> Void

    let manifest: ProviderPluginManifest

    private let queue: DispatchQueue
    private let context: JSContext
    private let applyPrelude: JSValue
    private let transport: any ProviderHTTPTransport
    private let responseSizeLimit: Int
    private var cache: [String: (value: JSValue, expiresAt: Date)] = [:]
    private var retainedCallbacks: [UUID: [Any]] = [:]

    static func make(
        source: String,
        preludeSource: String,
        transport: any ProviderHTTPTransport,
        responseSizeLimit: Int) throws -> ProviderPluginWorker
    {
        let queue = DispatchQueue(label: "com.steipete.codexbar.provider-plugin.\(UUID().uuidString)")
        return try queue.sync {
            try ProviderPluginWorker(
                queue: queue,
                source: source,
                preludeSource: preludeSource,
                transport: transport,
                responseSizeLimit: responseSizeLimit)
        }
    }

    private init(
        queue: DispatchQueue,
        source: String,
        preludeSource: String,
        transport: any ProviderHTTPTransport,
        responseSizeLimit: Int) throws
    {
        guard let context = JSContext() else {
            throw ProviderPluginError.load("JavaScriptCore could not create a context")
        }
        self.queue = queue
        self.context = context
        self.transport = transport
        self.responseSizeLimit = responseSizeLimit

        var definition: JSValue?
        let defineProvider: @convention(block) (JSValue) -> Void = { value in
            definition = value
        }
        context.setObject(defineProvider, forKeyedSubscript: "defineProvider" as NSString)

        context.exception = nil
        guard let applyPrelude = context.evaluateScript(preludeSource), context.exception == nil else {
            throw ProviderPluginError.load(Self.exceptionMessage(context) ?? "prelude evaluation failed")
        }
        self.applyPrelude = applyPrelude

        context.exception = nil
        _ = context.evaluateScript(source)
        if let message = Self.exceptionMessage(context) {
            throw ProviderPluginError.load(message)
        }
        guard let definition else {
            throw ProviderPluginError.invalidManifest("plugin did not call defineProvider(...)")
        }
        self.manifest = try ProviderPluginManifest(definition: definition)
    }

    func globalType(of name: String) throws -> String {
        try self.queue.sync {
            self.context.exception = nil
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            let result = self.context.evaluateScript("typeof globalThis['\(escaped)']")
            if let message = Self.exceptionMessage(self.context) {
                throw ProviderPluginError.script(message)
            }
            return result?.toString() ?? "undefined"
        }
    }

    func fetch(
        secrets: [String: String],
        now: Date,
        completion: @escaping @Sendable (Result<UsageSnapshot, Error>) -> Void)
    {
        self.queue.async {
            self.beginFetch(secrets: secrets, now: now, completion: completion)
        }
    }

    private func beginFetch(
        secrets: [String: String],
        now: Date,
        completion: @escaping @Sendable (Result<UsageSnapshot, Error>) -> Void)
    {
        self.context.exception = nil
        let ctx = self.makeContext(secrets: secrets)
        guard self.context.exception == nil else {
            completion(.failure(ProviderPluginError.script(Self.exceptionMessage(self.context) ?? "ctx setup failed")))
            return
        }

        let callbackID = UUID()
        let resolve: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self else { return }
            defer { self.retainedCallbacks[callbackID] = nil }
            do {
                let snapshot = try ProviderPluginSnapshotMapper.map(value, provider: self.manifest.id, now: now)
                completion(.success(snapshot))
            } catch {
                completion(.failure(error))
            }
        }
        let reject: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self else { return }
            defer { self.retainedCallbacks[callbackID] = nil }
            completion(.failure(ProviderPluginError.script(self.message(from: value))))
        }
        self.retainedCallbacks[callbackID] = [resolve, reject]

        guard let result = self.manifest.fetchUsage.call(withArguments: [ctx]) else {
            self.retainedCallbacks[callbackID] = nil
            completion(.failure(ProviderPluginError
                    .script(Self.exceptionMessage(self.context) ?? "fetchUsage returned no value")))
            return
        }
        if let message = Self.exceptionMessage(self.context) {
            self.retainedCallbacks[callbackID] = nil
            completion(.failure(ProviderPluginError.script(message)))
            return
        }

        guard let then = result.forProperty("then"), then.isObject else {
            resolve(result)
            return
        }
        _ = result.invokeMethod("then", withArguments: [resolve, reject])
        if let message = Self.exceptionMessage(self.context) {
            self.retainedCallbacks[callbackID] = nil
            completion(.failure(ProviderPluginError.script(message)))
        }
    }

    private func makeContext(secrets: [String: String]) -> JSValue {
        let ctx = JSValue(newObjectIn: self.context)!
        let host = JSValue(newObjectIn: self.context)!

        let secretGet: @convention(block) (String) -> JSValue = { [weak self] key in
            guard let self else { return JSValue(undefinedIn: nil) }
            guard self.manifest.settings.contains(where: { $0.key == key }) else {
                self.context.exception = JSValue(
                    newErrorFromMessage: "secret key '\(key)' is not declared in settings",
                    in: self.context)
                return JSValue(undefinedIn: self.context)
            }
            guard let secret = secrets[key], !secret.isEmpty else {
                return JSValue(nullIn: self.context)
            }
            return JSValue(object: secret, in: self.context)
        }
        host.setObject(secretGet, forKeyedSubscript: "secretGet" as NSString)

        let http = self.makeHTTPBlock(secrets: secrets)
        host.setObject(http, forKeyedSubscript: "http" as NSString)

        let cacheGet: @convention(block) (String) -> JSValue = { [weak self] key in
            guard let self else { return JSValue(undefinedIn: nil) }
            guard let entry = self.cache[key], entry.expiresAt > Date() else {
                self.cache[key] = nil
                return JSValue(undefinedIn: self.context)
            }
            return entry.value
        }
        let cacheSet: @convention(block) (String, JSValue, Double) -> Void = { [weak self] key, value, ttl in
            guard let self, ttl.isFinite, ttl > 0 else { return }
            self.cache[key] = (value, Date().addingTimeInterval(min(ttl, 86400)))
        }
        host.setObject(cacheGet, forKeyedSubscript: "cacheGet" as NSString)
        host.setObject(cacheSet, forKeyedSubscript: "cacheSet" as NSString)

        let log: @convention(block) (String) -> Void = { [manifest] message in
            let logger = CodexBarLog.logger(LogCategories.provider(manifest.id, scope: "plugin"))
            logger.debug("\(message)")
        }
        host.setObject(log, forKeyedSubscript: "log" as NSString)

        _ = self.applyPrelude.call(withArguments: [ctx, host])
        return ctx
    }

    private func makeHTTPBlock(secrets: [String: String]) -> HTTPBlock {
        { [weak self] rawURL, options, wantsJSON, resolve, reject in
            self?.startHTTPRequest(
                rawURL: rawURL,
                options: options,
                secrets: secrets,
                callbacks: ProviderPluginHTTPRequestCallbacks(
                    wantsJSON: wantsJSON,
                    resolve: ProviderPluginJSValueBox(resolve),
                    reject: ProviderPluginJSValueBox(reject)))
        }
    }

    private func startHTTPRequest(
        rawURL: String,
        options: JSValue,
        secrets: [String: String],
        callbacks: ProviderPluginHTTPRequestCallbacks)
    {
        let request: URLRequest
        do {
            request = try self.makeRequest(rawURL: rawURL, options: options, secrets: secrets)
        } catch {
            self.reject(callbacks.reject, error: error)
            return
        }

        let worker = self
        let transport = self.transport
        let responseSizeLimit = self.responseSizeLimit
        Task.detached {
            do {
                let response = try await transport.response(for: request)
                guard response.data.count <= responseSizeLimit else {
                    throw ProviderPluginError.http("response exceeded the 5 MiB limit")
                }
                let payload = try ProviderPluginObjectBox(Self.responsePayload(
                    response,
                    wantsJSON: callbacks.wantsJSON))
                worker.queue.async {
                    let value = JSValue(object: payload.value, in: worker.context) ?? JSValue(nullIn: worker.context)
                    _ = callbacks.resolve.value.call(withArguments: [value as Any])
                }
            } catch {
                let failure = ProviderPluginError.http(error.localizedDescription)
                worker.queue.async {
                    worker.reject(callbacks.reject, error: failure)
                }
            }
        }
    }

    private func makeRequest(rawURL: String, options: JSValue, secrets: [String: String]) throws -> URLRequest {
        guard let url = URL(string: rawURL) else {
            throw ProviderPluginError.networkPolicy("request URL is invalid")
        }
        let origin = try ProviderPluginOrigin.normalizedOrigin(of: url)
        guard self.manifest.endpoints.contains(origin) else {
            throw ProviderPluginError.networkPolicy("origin '\(origin)' is not declared")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if options.isObject,
           let headers = options.forProperty("headers"),
           headers.isObject,
           let dictionary = headers.toDictionary() as? [String: Any]
        {
            for (name, rawValue) in dictionary {
                guard let value = rawValue as? String else {
                    throw ProviderPluginError.http("request header '\(name)' must be a string")
                }
                if name.caseInsensitiveCompare(self.manifest.auth.header) == .orderedSame {
                    throw ProviderPluginError.networkPolicy("plugins may not override the auth header")
                }
                request.setValue(value, forHTTPHeaderField: name)
            }
        }

        guard let secret = secrets[self.manifest.auth.secret], !secret.isEmpty else {
            throw ProviderPluginError.secretAccess("required auth secret is unavailable")
        }
        let authValue = self.manifest.auth.type == .bearer ? "Bearer \(secret)" : secret
        request.setValue(authValue, forHTTPHeaderField: self.manifest.auth.header)
        return request
    }

    private static func responsePayload(_ response: ProviderHTTPResponse, wantsJSON: Bool) throws -> [String: Any] {
        var headers: [String: String] = [:]
        for (key, value) in response.response.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        var payload: [String: Any] = [
            "status": response.statusCode,
            "headers": headers,
        ]
        if wantsJSON {
            do {
                payload["json"] = try JSONSerialization.jsonObject(with: response.data)
            } catch {
                throw ProviderPluginError.http("response was not valid JSON")
            }
        } else {
            guard let text = String(data: response.data, encoding: .utf8) else {
                throw ProviderPluginError.http("response body was not valid UTF-8")
            }
            payload["bodyText"] = text
        }
        return payload
    }

    private func reject(_ reject: ProviderPluginJSValueBox, error: Error) {
        let value = JSValue(newErrorFromMessage: error.localizedDescription, in: self.context)
        _ = reject.value.call(withArguments: [value as Any])
    }

    private func message(from value: JSValue) -> String {
        if value.isObject,
           let message = value.forProperty("message"),
           message.isString
        {
            return message.toString()
        }
        return value.toString()
    }

    private static func exceptionMessage(_ context: JSContext) -> String? {
        defer { context.exception = nil }
        guard let exception = context.exception else { return nil }
        if let message = exception.forProperty("message"), message.isString {
            return message.toString()
        }
        return exception.toString()
    }
}
#endif
