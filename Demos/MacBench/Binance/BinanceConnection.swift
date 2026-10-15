//
//  BinanceConnection.swift
//  NGTable Mac Bench
//
//  one WebSocket connection to Binance's market data streams, received and decoded
//  off the main thread like the feed's (FeedConnection): a few receives asked for at once, each
//  frame decoded on its own queue while the next one comes, reading paused while too much
//  waits for the main thread (FeedReadingGate). Streams are added with SUBSCRIBE requests, at
//  most 4 a second (Binance closes a connection sending more than 5 messages a second, pongs
//  included). Pings are answered by Network.framework.
//

import Foundation
import Network

/// What a connection received since it was last asked.
nonisolated struct BinanceReceived: Sendable {
    var messages: [BinanceMessage] = []
    var frames = 0
    var bytes = 0
    /// Time spent decoding, seconds.
    var decoding: Double = 0
    /// When each message's frame came off the network (µs since 1970, our clock).
    var receivedAt: [Double] = []
}

nonisolated final class BinanceConnection: @unchecked Sendable {
    /// A connection listens to 1,024 streams at most.
    static let streamLimit = 1_024
    /// Streams per SUBSCRIBE request, and the time between requests.
    static let subscribeChunk = 200
    static let subscribeInterval: DispatchTimeInterval = .milliseconds(260)

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "BinanceConnection", qos: .userInitiated)
    private let decodingQueue = DispatchQueue(label: "BinanceConnection.decoding", qos: .userInitiated)
    private let lock = NSLock()
    private var received = BinanceReceived()
    private var isClosed = false
    private var gate = FeedReadingGate(limit: (bytes: 8 * 1024 * 1024, frames: 20_000))
    private var outstanding = 0
    private static let receiveDepth = 4
    /// SUBSCRIBE requests waiting to go (on `queue`), and the next request id.
    private var pendingSubscriptions: [[String]] = []
    private var nextRequestID = 1
    private var isSubscribing = false
    /// The WebSocket is open (on `queue`): requests wait for it.
    private var isReady = false

    init(url: URL) {
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.maximumMessageSize = 64 * 1024 * 1024
        webSocket.autoReplyPing = true
        let parameters = NWParameters(tls: url.scheme == "wss" ? NWProtocolTLS.Options() : nil)
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        connection = NWConnection(to: .url(url), using: parameters)
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                isReady = true
                sendNextSubscription()
            case .failed(let error), .waiting(let error): finish("\(error.localizedDescription)")
            default: break
            }
        }
        connection.start(queue: queue)
        queue.async { [self] in fill() }
    }

    func close() {
        lock.lock()
        isClosed = true
        lock.unlock()
        connection.cancel()
    }

    /// Everything received since the last call.
    func take() -> BinanceReceived {
        lock.lock()
        defer { lock.unlock() }
        let taken = received
        received = BinanceReceived()
        if gate.taken(), !isClosed {
            queue.async { [self] in fill() }
        }
        return taken
    }

    /// Adds streams, in requests of `subscribeChunk`, spaced out.
    func subscribe(_ streams: [String]) {
        queue.async { [self] in
            pendingSubscriptions += stride(from: 0, to: streams.count, by: Self.subscribeChunk).map {
                Array(streams[$0..<min(streams.count, $0 + Self.subscribeChunk)])
            }
            sendNextSubscription()
        }
    }

    private func sendNextSubscription() {
        guard isReady, !isSubscribing, !pendingSubscriptions.isEmpty else { return }
        isSubscribing = true
        let streams = pendingSubscriptions.removeFirst()
        let request: [String: Any] = ["method": "SUBSCRIBE", "params": streams, "id": nextRequestID]
        nextRequestID += 1
        if let data = try? JSONSerialization.data(withJSONObject: request) {
            let context = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
            connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
        }
        queue.asyncAfter(deadline: .now() + Self.subscribeInterval) { [self] in
            isSubscribing = false
            sendNextSubscription()
        }
    }

    private func fill() {
        while outstanding < Self.receiveDepth { receiveNext() }
    }

    private func receiveNext() {
        outstanding += 1
        connection.receiveMessage { [self] content, context, _, error in
            outstanding -= 1
            if let error {
                decodingQueue.async { [self] in finish(error.localizedDescription) }
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if let metadata, metadata.opcode == .close {
                let reason = content.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                decodingQueue.async { [self] in finish((reason.isEmpty ? "закрыто сервером" : reason) + " (\(metadata.closeCode))") }
                return
            }
            // Pings (every 20 s; answered by Network.framework) and pongs carry no data.
            if let metadata, metadata.opcode != .text, metadata.opcode != .binary {
                fill()
                return
            }
            lock.lock()
            let readsOn = gate.received(bytes: content?.count ?? 0)
            lock.unlock()
            if readsOn { fill() }
            if let content {
                let receivedAt = Date().timeIntervalSince1970 * 1_000_000
                decodingQueue.async { [self] in decode(content, receivedAt: receivedAt) }
            }
        }
    }

    private func decode(_ content: Data, receivedAt: Double) {
        let start = ContinuousClock.now
        do {
            let message = try BinanceDecoder.decode(content)
            let elapsed = start.duration(to: .now).components
            lock.lock()
            defer { lock.unlock() }
            guard !isClosed else { return }
            if let message {
                received.messages.append(message)
                received.receivedAt.append(receivedAt)
            }
            received.frames += 1
            received.bytes += content.count
            received.decoding += Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        } catch {
            finish("Кадр не разобран: \(error)")
        }
    }

    private func finish(_ reason: String) {
        lock.lock()
        let wasClosed = isClosed
        isClosed = true
        if !wasClosed { received.messages.append(.closed(reason)) }
        lock.unlock()
        connection.cancel()
    }
}
