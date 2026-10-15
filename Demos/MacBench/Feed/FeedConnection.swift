//
//  FeedConnection.swift
//  NGTable Mac Bench
//
//  one WebSocket connection to an ngfeed server. Frames are received and decoded off
//  the main thread and wait in an inbox, which the main thread takes once per frame of the
//  screen; so the table gets one batch a frame however fast the feed is.
//
//  Network.framework rather than URLSessionWebSocketTask: its `receive()` goes through several
//  queues for every message and tops out near 20 000 messages a second (`hft` sends 45 000);
//  here the next message is asked for right in the callback, and the message is decoded on a
//  queue of its own meanwhile (in order).
//
//  What waits for the main thread is bounded (`inboxLimit`, FeedReadingGate): past it the
//  connection stops reading until the inbox is taken, so a client that can't keep up pushes
//  back on the server, which then conflates its changes, rather than piling up messages.
//

import Foundation
import Network

/// What the connection received since it was last asked.
nonisolated struct FeedReceived: Sendable {
    var messages: [FeedMessage] = []
    var frames = 0
    var bytes = 0
    /// Time spent decoding, seconds.
    var decoding: Double = 0
    /// Ages of the changes (from the server's `gen_ts`, ms) when their frame came off the
    /// network and when it was decoded: the first stages of the latency.
    var receivedAges: [Double] = []
    var decodedAges: [Double] = []
}

nonisolated final class FeedConnection: @unchecked Sendable {
    /// Frames as large as a snapshot part of a wide scenario (about 10 MB) pass, and so do the
    /// conflated messages of a client that fell behind: the server sends those whole, and on a
    /// million rows they grow to hundreds of megabytes (a snapshot of them is 406 MB).
    static let maximumMessageSize = 512 * 1024 * 1024
    /// Bytes or frames received and not taken yet past which reading stops.
    static let inboxLimit = (bytes: 8 * 1024 * 1024, frames: 5_000)

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "FeedConnection", qos: .userInitiated)
    private let decodingQueue = DispatchQueue(label: "FeedConnection.decoding", qos: .userInitiated)
    /// Used on `decodingQueue` only.
    private let decoder = FeedDecoder()
    private let lock = NSLock()
    private var received = FeedReceived()
    private var isClosed = false
    /// Received since the inbox was last taken (decoded or not yet).
    private var gate = FeedReadingGate(limit: FeedConnection.inboxLimit)
    /// Receives asked for and not answered yet (on `queue`): a few at once, so the network's
    /// queue has the next one while this one is handled (one at a time, the two queues took
    /// turns and topped out at the `hft` feed's rate).
    private var outstanding = 0
    private static let receiveDepth = 4

    init(url: URL) {
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.maximumMessageSize = Self.maximumMessageSize
        webSocket.autoReplyPing = true
        let parameters = NWParameters(tls: url.scheme == "wss" ? NWProtocolTLS.Options() : nil)
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        connection = NWConnection(to: .url(url), using: parameters)
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
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
    func take() -> FeedReceived {
        lock.lock()
        defer { lock.unlock() }
        let taken = received
        received = FeedReceived()
        if gate.taken(), !isClosed {
            queue.async { [self] in fill() }
        }
        return taken
    }

    /// A control message (`ping`, `resnapshot`, `pause`, `resume`, `configure`).
    func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        let context = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    /// Receives asked for up to `receiveDepth` (on `queue`).
    private func fill() {
        while outstanding < Self.receiveDepth { receiveNext() }
    }

    /// One message, then the next; each decoded on `decodingQueue` while the next one comes.
    /// Answers come in order, on `queue`.
    private func receiveNext() {
        outstanding += 1
        connection.receiveMessage { [self] content, context, _, error in
            outstanding -= 1
            if let error {
                decodingQueue.async { [self] in finish(error.localizedDescription) }
                return
            }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               metadata.opcode == .close {
                let reason = content.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                decodingQueue.async { [self] in finish((reason.isEmpty ? "закрыто сервером" : reason) + " (\(metadata.closeCode))") }
                return
            }
            lock.lock()
            let readsOn = gate.received(bytes: content?.count ?? 0)
            lock.unlock()
            if readsOn { fill() }   // Else once the inbox is taken.
            if let content {
                let receivedAt = Date().timeIntervalSince1970 * 1_000_000
                decodingQueue.async { [self] in decode(content, receivedAt: receivedAt) }
            }
        }
    }

    private func decode(_ content: Data, receivedAt: Double) {
        let start = ContinuousClock.now
        do {
            let message = try decoder.decode(content)
            let elapsed = start.duration(to: .now).components
            append(message, bytes: content.count, decoding: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                   receivedAt: receivedAt, decodedAt: Date().timeIntervalSince1970 * 1_000_000)
        } catch {
            finish("Кадр не разобран: \(error)")
        }
    }

    /// The connection ends: told once, unless the app closed it.
    private func finish(_ reason: String) {
        lock.lock()
        let wasClosed = isClosed
        isClosed = true
        if !wasClosed { received.messages.append(.closed(reason)) }
        lock.unlock()
        connection.cancel()
    }

    private func append(_ message: FeedMessage?, bytes: Int, decoding: Double, receivedAt: Double, decodedAt: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }   // Nothing after `.closed`.
        if let message { received.messages.append(message) }
        if let genTs = message?.genTs {
            received.receivedAges.append((receivedAt - Double(genTs)) / 1000)
            received.decodedAges.append((decodedAt - Double(genTs)) / 1000)
        }
        received.frames += 1
        received.bytes += bytes
        received.decoding += decoding
    }
}
