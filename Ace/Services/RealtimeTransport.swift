//
//  RealtimeTransport.swift
//  Ace
//
//  The wire under Live Mode.
//
//  `RealtimeTransport` is a two-method protocol: send an event, receive a stream
//  of them. Everything above it — the provider, the latency tracking, barge-in,
//  reconnection, the whole UI — is written against the protocol, which means:
//
//    • The entire Live Mode behaviour is testable against `MockRealtimeTransport`
//      with no key, no network, and no Xcode.
//    • Swapping transports is a one-line change.
//
//  See DECISIONS.md D24 for why the shipping transport is a WebSocket rather
//  than WebRTC.
//

import Foundation

// MARK: - Protocol

/// What connecting produced.
enum TransportState: Sendable, Equatable {
    case idle
    case connecting
    case connected(sessionID: String)
    case failed(String)
    case closed

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

protocol RealtimeTransport: AnyObject, Sendable {
    /// Open the connection. Returns once the server has acknowledged the session.
    func connect(apiKey: String, model: String) async throws -> String

    /// Send a client event.
    func send(_ event: RealtimeClientEvent) async throws

    /// Server events, in order.
    var events: AsyncStream<RealtimeServerEvent> { get }

    /// Close and release everything.
    func disconnect() async

    /// Round-trip time of the last keepalive, when known.
    ///
    /// Synchronous on purpose: an async getter would mean taking a lock inside
    /// an async context, which risks holding it across a suspension point (and
    /// is an error outright in the Swift 6 language mode).
    var lastRoundTrip: TimeInterval? { get }
}

// MARK: - WebSocket transport

/// The shipping transport: OpenAI Realtime over a WebSocket, using
/// `URLSessionWebSocketTask`. No third-party dependencies at all.
final class WebSocketRealtimeTransport: RealtimeTransport, @unchecked Sendable {

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var continuation: AsyncStream<RealtimeServerEvent>.Continuation?
    private var receiveLoop: Task<Void, Never>?
    private var roundTrip: TimeInterval?
    private let lock = NSLock()

    let events: AsyncStream<RealtimeServerEvent>

    init(session: URLSession = .shared) {
        self.session = session
        var capturedContinuation: AsyncStream<RealtimeServerEvent>.Continuation!
        self.events = AsyncStream { capturedContinuation = $0 }
        self.continuation = capturedContinuation
    }

    var lastRoundTrip: TimeInterval? {
        lock.withLock { roundTrip }
    }

    // MARK: Connecting

    func connect(apiKey: String, model: String) async throws -> String {
        // Mint a short-lived client token rather than putting the long-lived key
        // on the socket. It's scoped to one session and expires in about a
        // minute, so an intercepted token is worth almost nothing — whereas an
        // intercepted key is worth everything.
        //
        // Minting is best-effort: if the endpoint is unavailable we fall back to
        // the key, because a working session beats a marginally safer failure.
        let credential: String
        do {
            credential = try await RealtimeSessionMinter.mint(
                apiKey: apiKey, model: model,
                voice: VoiceRoster.default.realtimeVoiceName, session: session
            ).token
        } catch {
            credential = apiKey
        }

        guard var components = URLComponents(string: "wss://api.openai.com/v1/realtime") else {
            throw AIProviderError.transport("Bad realtime URL")
        }
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = components.url else {
            throw AIProviderError.transport("Bad realtime URL")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        // Short enough that a dead network surfaces quickly rather than leaving
        // the student staring at a spinner.
        request.timeoutInterval = 12

        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        startReceiving(on: task)

        // The server sends `session.created` unprompted once the socket is up.
        // Waiting for it — rather than for the socket alone — is what makes
        // "connected" mean the session is actually usable.
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [events] in
                for await event in events {
                    if case .sessionCreated(let id) = event { return id }
                    if case .error(_, let message) = event {
                        throw AIProviderError.transport(message)
                    }
                }
                throw AIProviderError.transport("Connection closed during handshake")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(12))
                throw AIProviderError.transport("Timed out waiting for the session")
            }

            guard let id = try await group.next() else {
                throw AIProviderError.transport("Handshake produced nothing")
            }
            group.cancelAll()
            return id
        }
    }

    private func startReceiving(on task: URLSessionWebSocketTask) {
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard let self else { return }

                    switch message {
                    case .data(let data):
                        self.continuation?.yield(RealtimeServerEvent.decode(data))
                    case .string(let text):
                        if let data = text.data(using: .utf8) {
                            self.continuation?.yield(RealtimeServerEvent.decode(data))
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    // A closed socket is not necessarily an error — the app may
                    // have ended the session. Either way the stream must finish
                    // so anything awaiting it wakes up.
                    guard let self else { return }
                    if !Task.isCancelled {
                        self.continuation?.yield(.error(code: "transport",
                                                        message: error.localizedDescription))
                    }
                    self.continuation?.finish()
                    return
                }
            }
        }
    }

    // MARK: Sending

    func send(_ event: RealtimeClientEvent) async throws {
        guard let task else { throw AIProviderError.notConfigured }
        let data = try event.encoded()
        try await task.send(.data(data))
    }

    /// Measure round-trip time with a WebSocket ping.
    @discardableResult
    func measureRoundTrip() async -> TimeInterval? {
        guard let task else { return nil }
        let start = Date()
        return await withCheckedContinuation { continuation in
            task.sendPing { [weak self] error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                let elapsed = Date().timeIntervalSince(start)
                self?.lock.withLock { self?.roundTrip = elapsed }
                continuation.resume(returning: elapsed)
            }
        }
    }

    // MARK: Closing

    func disconnect() async {
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        continuation?.finish()
        continuation = nil
    }
}

// MARK: - Ephemeral sessions (the WebRTC handshake)

/// Mints a short-lived client token from the standard API key.
///
/// This is the half of the WebRTC flow that doesn't need a media engine, and
/// it's worth having regardless of transport: an ephemeral token is scoped to
/// one session and expires in a minute, so it is strictly safer to put on a wire
/// than the real key.
enum RealtimeSessionMinter {

    struct Ephemeral: Sendable, Equatable {
        let token: String
        let expiresAt: Date
        var isExpired: Bool { Date() >= expiresAt }
    }

    /// POST /v1/realtime/sessions
    static func mint(apiKey: String,
                     model: String,
                     voice: String,
                     session: URLSession = .shared) async throws -> Ephemeral {
        guard let url = URL(string: "https://api.openai.com/v1/realtime/sessions") else {
            throw AIProviderError.transport("Bad sessions URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        request.timeoutInterval = 12
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["model": model, "voice": voice]
        )

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let secret = object["client_secret"] as? [String: Any],
              let token = secret["value"] as? String else {
            throw AIProviderError.transport("Couldn't read the session token")
        }

        // `expires_at` is a Unix timestamp. Fall back to a conservative minute.
        let expiry = (secret["expires_at"] as? Double).map(Date.init(timeIntervalSince1970:))
            ?? Date().addingTimeInterval(60)

        return Ephemeral(token: token, expiresAt: expiry)
    }

    /// Turn an HTTP failure into something a student can act on.
    static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw AIProviderError.transport("That key was rejected. Check it's the whole key and still active.")
        case 429:
            throw AIProviderError.rateLimited
        case 500..<600:
            throw AIProviderError.transport("OpenAI is having trouble right now. Demo Mode still works.")
        default:
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0?["error"] as? [String: Any])?["message"] as? String }
            throw AIProviderError.transport(detail ?? "Request failed (\(http.statusCode)).")
        }
    }
}
