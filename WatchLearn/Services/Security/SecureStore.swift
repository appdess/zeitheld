import Foundation

protocol SecureStore: Sendable {
    func data(for key: String) throws -> Data?
    func set(_ data: Data, for key: String) throws
    func removeValue(for key: String) throws
}

enum SecureStoreError: LocalizedError, Equatable {
    case unexpectedStatus(Int32)
    case invalidValue

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Secure storage failed with status \(status)."
        case .invalidValue:
            return "The secure value could not be encoded."
        }
    }
}
