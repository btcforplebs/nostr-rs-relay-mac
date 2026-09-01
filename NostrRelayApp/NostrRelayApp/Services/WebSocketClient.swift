import Foundation
import Combine

class WebSocketClient: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    private var webSocketTask: URLSessionWebSocketTask?
    @Published var isConnected = false
    let messageSubject = PassthroughSubject<String, Never>()

    private var retryCount = 0
    private var retryScheduled = false
    private var isIntentionalDisconnect = false
    private var currentURL: URL?
    private var pingTimer: Timer?

    /// Detects sockets that die without a delegate callback (e.g. after sleep/wake).
    private static let healthPingInterval: TimeInterval = 30
    private static let maxRetryDelay: TimeInterval = 15

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    func connect(url: URL) {
        currentURL = url
        isIntentionalDisconnect = false
        retryCount = 0
        performConnect(url: url)
    }

    private func performConnect(url: URL) {
        // Cancel existing task internally without triggering "intentional" disconnect logic
        webSocketTask?.cancel()

        let task = Self.session.webSocketTask(with: url)
        task.delegate = self
        webSocketTask = task
        task.resume()
        receiveMessage()
    }

    func disconnect() {
        isIntentionalDisconnect = true
        stopHealthPing()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        isConnected = false
    }

    func send(text: String) {
        let message = URLSessionWebSocketTask.Message.string(text)
        webSocketTask?.send(message) { [weak self] error in
            if error != nil {
                self?.handleConnectionFailure()
            }
        }
    }

    private func receiveMessage() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self] result in
            guard let self = self else { return }
            guard !self.isIntentionalDisconnect else { return }

            switch result {
            case .failure:
                self.handleConnectionFailure()
            case .success(let message):
                switch message {
                case .string(let text):
                    self.messageSubject.send(text)
                case .data(_):
                    break
                @unknown default:
                    break
                }
                self.receiveMessage()
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async {
            self.isConnected = true
            self.retryCount = 0 // Reset backoff on success
            self.startHealthPing()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        handleConnectionFailure()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil {
            handleConnectionFailure()
        }
    }

    // MARK: - Reconnection

    /// Funnel every failure signal (close, error, failed send/receive/ping) into
    /// one main-queue path so concurrent callbacks schedule at most one retry.
    private func handleConnectionFailure() {
        DispatchQueue.main.async {
            guard !self.isIntentionalDisconnect else { return }
            self.isConnected = false
            self.stopHealthPing()
            self.scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard !retryScheduled, let url = currentURL else { return }
        retryScheduled = true

        // Exponential backoff, capped; retry forever so the viewer recovers
        // no matter how long the relay is down.
        let delay = min(0.5 * pow(2.0, Double(retryCount)), Self.maxRetryDelay)
        retryCount += 1

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.retryScheduled = false
            guard !self.isIntentionalDisconnect else { return }
            self.performConnect(url: url)
        }
    }

    // MARK: - Health ping

    private func startHealthPing() {
        stopHealthPing()
        pingTimer = Timer.scheduledTimer(withTimeInterval: Self.healthPingInterval, repeats: true) { [weak self] _ in
            self?.webSocketTask?.sendPing { error in
                if error != nil {
                    self?.handleConnectionFailure()
                }
            }
        }
    }

    private func stopHealthPing() {
        pingTimer?.invalidate()
        pingTimer = nil
    }
}

class EventViewerService: ObservableObject {
    @Published var events: [NostrEvent] = []
    @Published var isConnected: Bool = false
    /// True while the service should be holding a connection (even mid-retry).
    /// Used by callers to decide whether to connect/disconnect, so a temporary
    /// drop doesn't cause a redundant teardown + reconnect.
    @Published var isActive: Bool = false

    private var client: WebSocketClient?
    private var cancellables = Set<AnyCancellable>()
    private var seenEventIDs = Set<String>()
    private let processingQueue = DispatchQueue(label: "com.nostrrelay.processing", qos: .utility)
    private let decoder = JSONDecoder()
    private var config: RelayConfig?

    // Batch incoming events and flush to the UI at most once per second
    private var pendingEvents: [NostrEvent] = []
    private var flushScheduled = false
    private let maxBufferedEvents = 500

    // Fixed id: re-REQ with the same id replaces the subscription server-side,
    // so filter changes never leak old subscriptions (which would double traffic).
    private let subscriptionId = "app-viewer"

    func connect(port: Int, config: RelayConfig) {
        self.config = config
        disconnect()

        // Connect to localhost on configured port
        let urlString = "ws://127.0.0.1:\(port)"
        guard let url = URL(string: urlString) else { return }

        let client = WebSocketClient()
        self.client = client
        isActive = true

        // Handle incoming messages
        client.messageSubject
            .receive(on: processingQueue)
            .sink { [weak self] message in
                self?.processMessage(message)
            }
            .store(in: &cancellables)

        // Handle connection state
        client.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                self?.isConnected = connected
                if connected {
                    self?.subscribe()
                }
            }
            .store(in: &cancellables)

        client.connect(url: url)
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        cancellables.removeAll()
        isConnected = false
        isActive = false
        processingQueue.async { [weak self] in
            self?.pendingEvents.removeAll()
        }
    }

    func clear() {
        events.removeAll()
        seenEventIDs.removeAll()
    }

    private var currentKinds: [Int]? = nil

    func updateFilter(kinds: [Int]?) {
        self.currentKinds = kinds
        subscribe()
    }

    private func subscribe() {
        guard let client = client else { return }

        var filter: [String: Any] = ["limit": 50]
        if let kinds = currentKinds, !kinds.isEmpty {
            filter["kinds"] = kinds
        }

        let req: [Any] = ["REQ", subscriptionId, filter]

        if let data = try? JSONSerialization.data(withJSONObject: req),
           let text = String(data: data, encoding: .utf8) {
            client.send(text: text)
        }
    }

    /// Decodes ["EVENT", subId, {...}] in a single pass; other frame types
    /// (EOSE, NOTICE, OK, AUTH) yield a nil event without error.
    private struct RelayFrame: Decodable {
        let event: NostrEvent?

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            guard try container.decode(String.self) == "EVENT" else {
                self.event = nil
                return
            }
            _ = try container.decode(String.self) // subscription id
            self.event = try container.decode(NostrEvent.self)
        }
    }

    private func processMessage(_ message: String) {
        guard let data = message.data(using: .utf8),
              let frame = try? decoder.decode(RelayFrame.self, from: data),
              let event = frame.event else {
            return
        }

        // Apply client-side spam filtering
        if let config = self.config, SpamFilterService.shouldFilter(event: event, config: config) {
            // Event is filtered, don't show it in the viewer
            return
        }

        // Buffer on the processing queue; flush to the main thread at most 1x/sec
        pendingEvents.append(event)
        if !flushScheduled {
            flushScheduled = true
            processingQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.flushPendingEvents()
            }
        }
    }

    private func flushPendingEvents() {
        let batch = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        flushScheduled = false
        guard !batch.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for event in batch {
                // O(1) dedup via Set lookup
                guard self.seenEventIDs.insert(event.id).inserted else { continue }
                self.events.insert(event, at: 0)
            }
            // Keep buffer size reasonable
            while self.events.count > self.maxBufferedEvents {
                let removed = self.events.removeLast()
                self.seenEventIDs.remove(removed.id)
            }
        }
    }
}
