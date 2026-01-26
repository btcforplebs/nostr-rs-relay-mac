import Foundation
import Combine

class WebSocketClient: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    private var webSocketTask: URLSessionWebSocketTask?
    @Published var isConnected = false
    let messageSubject = PassthroughSubject<String, Never>()
    
    private var retryCount = 0
    private let maxRetries = 10
    private var isIntentionalDisconnect = false
    private var currentURL: URL?
    
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config)
    }()
    
    func connect(url: URL) {
        currentURL = url
        isIntentionalDisconnect = false
        retryCount = 0
        performConnect(url: url)
    }
    
    private func performConnect(url: URL) {
        // Cancel existing task internally without triggering "intentional" disconnect logic logic
        webSocketTask?.cancel()
        
        let task = Self.session.webSocketTask(with: url)
        task.delegate = self
        webSocketTask = task
        task.resume()
        receiveMessage()
    }
    
    func disconnect() {
        isIntentionalDisconnect = true
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        isConnected = false
    }
    
    func send(text: String) {
        let message = URLSessionWebSocketTask.Message.string(text)
        webSocketTask?.send(message) { error in
            if let error = error {
                print("WebSocket send error: \(error)")
            }
        }
    }
    
    private func receiveMessage() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self] result in
            guard let self = self else { return }
            guard !self.isIntentionalDisconnect else { return }
            
            switch result {
            case .failure(_):
                // Don't spam console if we act on it later
                // print("WebSocket receive failure: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isConnected = false
                    // Receive failure usually means disconnection, delegate didCompleteWithError might also be called
                }
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
            self.retryCount = 0 // Reset retries on success
        }
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async {
            self.isConnected = false
            if !self.isIntentionalDisconnect {
                self.scheduleRetry()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let _ = error {
            DispatchQueue.main.async {
                self.isConnected = false
                if !self.isIntentionalDisconnect {
                    self.scheduleRetry()
                }
            }
        }
    }
    
    private func scheduleRetry() {
        guard retryCount < maxRetries, let url = currentURL else { return }
        
        retryCount += 1
        let delay = Double(retryCount) * 0.5 // 0.5s, 1.0s, 1.5s...
        
        // print("WebSocket disconnected. Retrying in \(delay)s (Attempt \(retryCount)/\(maxRetries))...")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.performConnect(url: url)
        }
    }
}

class EventViewerService: ObservableObject {
    @Published var events: [NostrEvent] = []
    @Published var isConnected: Bool = false
    
    private var client: WebSocketClient?
    private var cancellables = Set<AnyCancellable>()
    private let processingQueue = DispatchQueue(label: "com.nostrrelay.processing", qos: .userInitiated)
    
    func connect(port: Int) {
        disconnect()
        
        // Connect to localhost on configured port
        let urlString = "ws://127.0.0.1:\(port)"
        guard let url = URL(string: urlString) else { return }
        
        let client = WebSocketClient()
        self.client = client
        
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
    }
    
    func clear() {
        events.removeAll()
    }
    
    // START CHANGE
    private var currentKinds: [Int]? = nil
    
    func updateFilter(kinds: [Int]?) {
        self.currentKinds = kinds
        subscribe()
    }
    
    private func subscribe() {
        guard let client = client else { return }
        let subscriptionId = "app-viewer-\(UUID().uuidString.prefix(4))"
        
        var filter: [String: Any] = ["limit": 100]
        if let kinds = currentKinds, !kinds.isEmpty {
            filter["kinds"] = kinds
        }
        
        let req: [Any] = ["REQ", subscriptionId, filter]
        
        if let data = try? JSONSerialization.data(withJSONObject: req),
           let text = String(data: data, encoding: .utf8) {
            client.send(text: text)
        }
    }
    // END CHANGE
    
    private func processMessage(_ message: String) {
        // Simple fast parsing
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count >= 3,
              let type = json[0] as? String,
              type == "EVENT",
              let eventDict = json[2] as? [String: Any],
              let eventData = try? JSONSerialization.data(withJSONObject: eventDict),
              let event = try? JSONDecoder().decode(NostrEvent.self, from: eventData) else {
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Deduplicate
            if !self.events.contains(where: { $0.id == event.id }) {
                self.events.insert(event, at: 0)
                // Keep buffer size reasonable
                if self.events.count > 1000 {
                    self.events = Array(self.events.prefix(1000))
                }
            }
        }
    }
}
