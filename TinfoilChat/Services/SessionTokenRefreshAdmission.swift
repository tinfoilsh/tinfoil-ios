import Foundation

struct SessionTokenRefreshAdmission {
    private(set) var requestID: UUID?

    mutating func begin() -> UUID? {
        guard requestID == nil else { return nil }
        let id = UUID()
        requestID = id
        return id
    }

    mutating func finish(_ id: UUID) {
        if requestID == id { requestID = nil }
    }

    mutating func reset() {
        requestID = nil
    }
}
