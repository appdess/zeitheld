import Foundation

enum RealtimeWebSocketMessage: Equatable, Sendable {
    case text(String)
    case data(Data)
}

protocol RealtimeWebSocketTransporting: Sendable {
    func connect(request: URLRequest) async throws
    func send(text: String) async throws
    func receive() async throws -> RealtimeWebSocketMessage
    func disconnect() async
}

enum RealtimeWebSocketTransportError: LocalizedError, Equatable, Sendable {
    case alreadyConnected
    case disconnected
    case messageTooLarge

    var errorDescription: String? {
        switch self {
        case .alreadyConnected:
            "The WebSocket transport is already connected."
        case .disconnected:
            "The WebSocket transport is disconnected."
        case .messageTooLarge:
            "The Realtime service returned an oversized WebSocket message."
        }
    }
}

enum RealtimeWebSocketMessageValidator {
    static func validate(_ message: RealtimeWebSocketMessage) throws {
        let byteCount: Int
        switch message {
        case let .text(text):
            byteCount = text.utf8.count
        case let .data(data):
            byteCount = data.count
        }
        guard byteCount <= RealtimeConstants.maxServerEventBytes else {
            throw RealtimeWebSocketTransportError.messageTooLarge
        }
    }
}

enum RealtimeWebSocketRequestFactory {
    static func makeRequest(
        clientSecret: RealtimeClientSecret,
        safetyIdentifier: RealtimeSafetyIdentifier
    ) -> URLRequest {
        var request = URLRequest(url: RealtimeConstants.webSocketURL)
        request.timeoutInterval = 20
        request.setValue(
            "Bearer \(clientSecret.value)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            safetyIdentifier.headerValue,
            forHTTPHeaderField: "OpenAI-Safety-Identifier"
        )
        return request
    }
}

actor URLSessionRealtimeWebSocketTransport: RealtimeWebSocketTransporting {
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func connect(request: URLRequest) async throws {
        guard task == nil else {
            throw RealtimeWebSocketTransportError.alreadyConnected
        }
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = RealtimeConstants.maxServerEventBytes
        task = socket
        socket.resume()
    }

    func send(text: String) async throws {
        guard let task else {
            throw RealtimeWebSocketTransportError.disconnected
        }
        try await task.send(.string(text))
    }

    func receive() async throws -> RealtimeWebSocketMessage {
        guard let task else {
            throw RealtimeWebSocketTransportError.disconnected
        }
        let message: RealtimeWebSocketMessage
        switch try await task.receive() {
        case let .string(text):
            message = .text(text)
        case let .data(data):
            message = .data(data)
        @unknown default:
            throw RealtimeServiceError.unsupportedWebSocketMessage
        }
        try RealtimeWebSocketMessageValidator.validate(message)
        return message
    }

    func disconnect() async {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}
