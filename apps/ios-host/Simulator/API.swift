import Foundation
import Security
@MainActor final class API {
    static let shared = API()
    var baseURL: URL { URL(string: UserDefaults.standard.string(forKey: "apiURL") ?? "http://localhost:8000")! }
    var token: String? {
        get { Keychain.read("session") }
        set { Keychain.write("session", value: newValue) }
    }
    func request(_ path: String, method: String = "GET", body: [String:Any]? = nil) async throws -> Any {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw SimError.message("无效 API 地址") }
        var req = URLRequest(url: url); req.httpMethod = method; req.timeoutInterval = 30
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data,response) = try await URLSession.shared.data(for: req)
        let object = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let dict = object as? [String:Any]
            throw SimError.message(dict?["message"] as? String ?? "请求失败：\(String(data: data, encoding: .utf8) ?? "")")
        }
        return object
    }
    func installTicket(appId: String, buildId: String?) async throws -> Ticket {
        let object = try await request("/v1/store/apps/\(appId)/install-ticket", method: "POST", body: buildId.map { ["build_id":$0] } ?? [:])
        return try JSONDecoder().decode(Ticket.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
enum Keychain {
    private static func query(_ key: String) -> [String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"fun.zihang.retro6",kSecAttrAccount as String:key] }
    static func read(_ key: String) -> String? {
        var q = query(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(_ key: String, value: String?) {
        let q = query(key); SecItemDelete(q as CFDictionary)
        if let value { var add = q; add[kSecValueData as String] = Data(value.utf8); add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly; SecItemAdd(add as CFDictionary,nil) }
    }
}
extension API {
    func uploadScreenshot(feedbackId:String,png:Data) async throws {
        guard png.count <= 2*1024*1024 else { throw SimError.message("截图超过 2 MiB") }
        let boundary = "Retro6-"+UUID().uuidString
        var req = URLRequest(url:baseURL.appendingPathComponent("v1/beta/feedback/\(feedbackId)/screenshot"));req.httpMethod = "POST"
        req.setValue("Bearer \(token ?? "")",forHTTPHeaderField:"Authorization");req.setValue("multipart/form-data; boundary=\(boundary)",forHTTPHeaderField:"Content-Type")
        var data = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"feedback.png\"\r\nContent-Type: image/png\r\n\r\n".utf8);data.append(png);data.append(Data("\r\n--\(boundary)--\r\n".utf8));req.httpBody = data
        let (_,response) = try await URLSession.shared.data(for:req)
        guard let r = response as? HTTPURLResponse,r.statusCode == 200 else { throw SimError.message("截图上传失败；文字反馈已保留") }
    }
}
