import Foundation
import CryptoKit
import ZIPFoundation
@MainActor final class AppManager {
    static let shared = AppManager()
    let root: URL
    private(set) var apps: [InstalledApp] = []
    private var activeInstalls = Set<String>()
    private let fm = FileManager.default
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Retro6",isDirectory:true)
        try? fm.createDirectory(at:self.root,withIntermediateDirectories:true)
        if let data = try? Data(contentsOf:self.root.appendingPathComponent("installed.json")), let saved = try? JSONDecoder().decode([InstalledApp].self,from:data) { apps = saved }
        // Orphan temporary downloads can be safely cleared after a terminated installation.
        for file in (try? fm.contentsOfDirectory(at:self.root,includingPropertiesForKeys:nil)) ?? [] where file.lastPathComponent.hasPrefix("staging-") { try? fm.removeItem(at:file) }
    }
    func bundle(_ a: InstalledApp) -> URL { root.appendingPathComponent("bundles/\(a.id)/\(a.buildId)",isDirectory:true) }
    func save(_ next: [InstalledApp]) throws {
        try JSONEncoder().encode(next).write(to:root.appendingPathComponent("installed.json"),options:.atomic)
        apps = next
        NotificationCenter.default.post(name:Notification.Name("InstalledChanged"),object:nil)
    }
    func install(_ t: Ticket, betaExpiry: Double? = nil) async throws {
        guard UUID(uuidString:t.appId) != nil, UUID(uuidString:t.buildId) != nil else { throw SimError.message("非法构建标识") }
        guard !activeInstalls.contains(t.appId) else { throw SimError.message("应用正在安装") }
        activeInstalls.insert(t.appId); defer { activeInstalls.remove(t.appId) }
        guard t.expiresAt > Date().timeIntervalSince1970 else { throw SimError.message("下载票据已过期") }
        guard let keyText = UserDefaults.standard.string(forKey:"trustedKey"), let key = Data(base64Encoded:keyText), let payload = Data(base64Encoded:t.payload), let signature = Data(base64Encoded:t.signature) else { throw SimError.message("请在设置中配置经过核对的 Ed25519 公钥") }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation:key)
        guard publicKey.isValidSignature(signature,for:payload) else { throw SimError.message("构建签名验证失败") }
        let signed = try JSONDecoder().decode(SignedMetadata.self,from:payload)
        let keyId = SHA256.hash(data:key).map { String(format:"%02x",$0) }.joined().prefix(16)
        guard String(keyId) == t.signatureKeyId, signed.appId == t.appId, signed.buildId == t.buildId, signed.version == t.version, signed.sha256 == t.sha256, signed.bundleId == t.manifest.id, signed.permissions == t.manifest.permissions else { throw SimError.message("签名元数据不匹配") }
        guard let url = URL(string:t.downloadUrl,relativeTo:API.shared.baseURL)?.absoluteURL,
              url.scheme == "https" || (url.scheme == "http" && url.host == API.shared.baseURL.host && url.scheme == API.shared.baseURL.scheme),
              url.user == nil, url.password == nil else { throw SimError.message("下载来源不可信") }
        let (download,response) = try await URLSession.shared.download(from:url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw SimError.message("包下载失败") }
        let attrs = try fm.attributesOfItem(atPath:download.path)
        guard ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 20*1024*1024 else { throw SimError.message("下载包超过配额") }
        let bytes = try Data(contentsOf:download,options:.mappedIfSafe)
        guard SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined() == signed.sha256 else { throw SimError.message("应用包摘要不匹配") }
        let staging = root.appendingPathComponent("staging-\(UUID().uuidString)",isDirectory:true)
        try fm.createDirectory(at:staging,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:staging) }
        let archive = try Archive(url:download,accessMode:.read)
        var total: UInt64 = 0; var paths = Set<String>(); var count = 0
        let allowed = Set(["html","css","js","json","png","jpg","jpeg","webp","gif","woff","woff2","txt","mp3","wav"])
        for entry in archive {
            count += 1; total += UInt64(entry.uncompressedSize)
            guard count <= 1000, total <= 60*1024*1024, entry.uncompressedSize <= 10*1024*1024, safeRelativePath(entry.path), entry.type != .symlink, paths.insert(entry.path.lowercased()).inserted else { throw SimError.message("非法 ZIP 文件或解压配额超限") }
            if entry.type == .file { guard allowed.contains(URL(fileURLWithPath:entry.path).pathExtension.lowercased()) else { throw SimError.message("不支持的包资源") } }
        }
        for entry in archive {
            let destination = staging.appendingPathComponent(entry.path).standardizedFileURL
            guard destination.path.hasPrefix(staging.path+"/") else { throw SimError.message("路径逃逸") }
            try fm.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
            _ = try archive.extract(entry,to:destination)
        }
        let manifest = try JSONDecoder().decode(Manifest.self,from:Data(contentsOf:staging.appendingPathComponent("manifest.json")))
        guard manifest == t.manifest, manifest.schemaVersion == 1, manifest.runtime == "web", manifest.permissions.allSatisfy({$0 == "storage"}), Set(manifest.permissions).count == manifest.permissions.count, safeRelativePath(manifest.entry), safeRelativePath(manifest.icon), fm.fileExists(atPath:staging.appendingPathComponent(manifest.entry).path), fm.fileExists(atPath:staging.appendingPathComponent(manifest.icon).path) else { throw SimError.message("应用清单校验失败") }
        let item = InstalledApp(id:t.appId,buildId:t.buildId,version:t.version,channel:t.channel,manifest:manifest,installedAt:Date(),expiresAt:t.channel == "beta" ? betaExpiry : nil)
        let target = bundle(item);try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
        if !fm.fileExists(atPath:target.path) { try fm.moveItem(at:staging,to:target) }
        var next = apps;next.removeAll { $0.id == item.id };next.append(item)
        do { try save(next) } catch { if !apps.contains(where:{$0.buildId == item.buildId}) { try? fm.removeItem(at:target) };throw error }
        // Keep old bundle directories until a future cleanup; live sessions may still reference them.
        _ = try? await API.shared.request("/v1/store/apps/\(item.id)/installed",method:"POST",body:["build_id":item.buildId])
    }
    func uninstall(_ a: InstalledApp, keepData: Bool = false) throws {
        try save(apps.filter{$0.id != a.id})
        try? fm.removeItem(at:root.appendingPathComponent("bundles/\(a.id)"))
        if !keepData { try? fm.removeItem(at:root.appendingPathComponent("private/\(a.id).json")) }
        Task { _ = try? await API.shared.request("/v1/store/apps/\(a.id)/installed",method:"DELETE") }
    }
    func storage(_ appId: String) -> [String:String] {
        guard let data = try? Data(contentsOf:root.appendingPathComponent("private/\(appId).json")) else { return [:] }
        return (try? JSONDecoder().decode([String:String].self,from:data)) ?? [:]
    }
    func writeStorage(_ value: [String:String], for appId: String) throws {
        guard UUID(uuidString:appId) != nil else { throw SimError.message("无效应用身份") }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 1024*1024, value.count <= 100 else { throw SimError.message("应用存储配额超限（1 MiB / 100 项）") }
        let dir = root.appendingPathComponent("private",isDirectory:true);try fm.createDirectory(at:dir,withIntermediateDirectories:true)
        try data.write(to:dir.appendingPathComponent("\(appId).json"),options:.atomic)
    }
}
