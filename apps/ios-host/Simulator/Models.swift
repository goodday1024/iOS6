import Foundation
struct Manifest: Codable, Equatable {
    let schemaVersion: Int
    let id, name, version, runtime, entry, icon: String
    let permissions: [String]
    let orientation: String?
    let minSimulatorVersion: String?
}
struct InstalledApp: Codable {
    let id, buildId, version, channel: String
    let manifest: Manifest
    let installedAt: Date
    let expiresAt: Double?
}
struct Ticket: Codable {
    let buildId, appId, version, channel, sha256, payload, signature, signatureKeyId, downloadUrl: String
    let manifest: Manifest
    let expiresAt: Double
}
struct SignedMetadata: Codable {
    let appId, buildId, bundleId, version, sha256: String
    let permissions: [String]
}
enum SimError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
func safeRelativePath(_ path: String) -> Bool {
    !path.isEmpty && !path.contains("//") && !path.hasSuffix("/.") && !path.contains("/./") && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":") && !path.contains("\0") && !path.split(separator: "/").contains(where: { $0 == ".." || $0.hasPrefix(".") })
}
