import Foundation
import CryptoKit

/// Recovery handles are separate from exportable diagnostics. They are scoped
/// to the authenticated account and backend; credentials are never persisted.
@MainActor
final class PendingLiveSessionStore {
    static let shared = PendingLiveSessionStore()
    static let storageKey = "live.pending-close.v1"
    private struct Entry: Codable {
        let id: String
        let owner: String
    }
    private let defaults: UserDefaults
    private var entries: [Entry]
    private var activeInProcess: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let data = defaults.data(forKey: Self.storageKey) ?? Data()
        entries = data.count <= 64_000 ? (try? JSONDecoder().decode([Entry].self, from: data)) ?? [] : []
        entries.removeAll { UUID(uuidString: $0.id) == nil }
    }

    func register(_ id: String, baseURL: URL, ownerID: String) {
        guard UUID(uuidString: id) != nil else { return }
        let owner = ownerKey(baseURL, ownerID)
        entries.removeAll { $0.id == id && $0.owner == owner }
        entries.append(Entry(id: id, owner: owner))
        activeInProcess.insert(id)
        persist()
    }

    func release(_ id: String) { activeInProcess.remove(id) }

    func pending(baseURL: URL, ownerID: String) -> [String] {
        let owner = ownerKey(baseURL, ownerID)
        return entries.filter { $0.owner == owner && !activeInProcess.contains($0.id) }.map(\.id)
    }

    func remove(_ id: String, baseURL: URL, ownerID: String) {
        let owner = ownerKey(baseURL, ownerID)
        entries.removeAll { $0.id == id && $0.owner == owner }
        activeInProcess.remove(id)
        persist()
    }

    /// A lost response keeps the handle for the next attempt/app launch. Only
    /// confirmed closure (or an authenticated 404 after server retention) clears it.
    func reconcile(baseURL: URL, ownerID: String,
                   close: (String) async throws -> Void) async throws {
        for id in pending(baseURL: baseURL, ownerID: ownerID) {
            try Task.checkCancellation()
            try await close(id)
            remove(id, baseURL: baseURL, ownerID: ownerID)
        }
    }

    private func ownerKey(_ base: URL, _ ownerID: String) -> String {
        SHA256.hash(data: Data("\(base.absoluteString)|\(ownerID)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    private func persist() { defaults.set(try? JSONEncoder().encode(entries), forKey: Self.storageKey) }
}
