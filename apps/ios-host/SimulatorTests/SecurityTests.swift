import XCTest
@testable import Retro6
final class SecurityTests:XCTestCase {
    func testPathConfinement() {
        for path in ["../secret","/tmp/a","assets/../../x","assets\\x","a:b",".env","a/.hidden"] { XCTAssertFalse(safeRelativePath(path),path) }
        for path in ["index.html","assets/icon.png","css/style.css"] { XCTAssertTrue(safeRelativePath(path),path) }
    }
    @MainActor func testAppStorageIsolationAndQuota() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let manager = AppManager(root:root);let a = UUID().uuidString,b = UUID().uuidString
        try manager.writeStorage(["note":"first"],for:a);try manager.writeStorage(["note":"second"],for:b)
        XCTAssertEqual(manager.storage(a)["note"],"first");XCTAssertEqual(manager.storage(b)["note"],"second")
        XCTAssertThrowsError(try manager.writeStorage(["large":String(repeating:"a",count:1024*1024+1)],for:a))
        XCTAssertEqual(manager.storage(a)["note"],"first")
    }
}
