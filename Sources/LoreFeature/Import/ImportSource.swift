import Foundation

enum ImportSourceError: Error, Equatable {
    case permissionDenied(String)
    case unsupportedSchema(String)
    case sourceUnavailable(String)
}

protocol ImportSource: Sendable {
    static var identifier: String { get }
    func scan() async throws -> [ImportItem]
}
