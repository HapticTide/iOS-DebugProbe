// DatabaseFamilyTests.swift
// DebugProbeTests
//
// 覆盖多库（库族）契约：
// - DatabaseDescriptor 的 family / familyRole / familyNote / familyOrder 在各条 descriptor 重建路径上不丢
// - DBTableInfo 的 kind / module / parentTable 判定（virtual / shadow）
// - JSON 编码出来的键名与WebUI 共享契约逐字一致
//

@testable import DebugProbe
import SQLite3
import XCTest

final class DatabaseFamilyTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        DatabaseRegistry.shared.clear()
        DatabaseRegistry.shared.refreshHandler = nil

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugProbeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        DatabaseRegistry.shared.clear()
        DatabaseRegistry.shared.refreshHandler = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeDescriptor(
        id: String,
        name: String = "App",
        isEncrypted: Bool = false,
        family: String? = nil,
        familyRole: String? = nil,
        familyNote: String? = nil,
        familyOrder: Int? = nil
    ) -> DatabaseDescriptor {
        DatabaseDescriptor(
            id: id,
            name: name,
            kind: "sqlite",
            location: .custom(description: "\(id).sqlite"),
            isEncrypted: isEncrypted,
            encryptionType: isEncrypted ? "SQLCipher" : nil,
            family: family,
            familyRole: familyRole,
            familyNote: familyNote,
            familyOrder: familyOrder
        )
    }

    private func fileURL(_ name: String) -> URL {
        tempDir.appendingPathComponent(name)
    }

    // MARK: - setFamily / 字段保留

    func testSetFamilyStoresAllFourFields() throws {
        let registry = DatabaseRegistry.shared
        registry.register(descriptor: makeDescriptor(id: "db_a"), url: fileURL("db_a.sqlite"))

        XCTAssertTrue(registry.setFamily(dbId: "db_a", family: "family-a", role: "role-1", note: "note-1", order: 0))

        let descriptor = try XCTUnwrap(registry.descriptor(for: "db_a"))
        XCTAssertEqual(descriptor.family, "family-a")
        XCTAssertEqual(descriptor.familyRole, "role-1")
        XCTAssertEqual(descriptor.familyNote, "note-1")
        XCTAssertEqual(descriptor.familyOrder, 0)
    }

    func testSetFamilyReturnsFalseForUnknownDatabase() {
        XCTAssertFalse(DatabaseRegistry.shared.setFamily(dbId: "not-registered", family: "family-a"))
    }

    func testSetFamilyWithNilClearsAnnotation() throws {
        let registry = DatabaseRegistry.shared
        registry.register(descriptor: makeDescriptor(id: "db_a"), url: fileURL("db_a.sqlite"))
        registry.setFamily(dbId: "db_a", family: "family-a", role: "role-1", note: "note-5", order: 0)

        registry.setFamily(dbId: "db_a", family: nil, role: nil, note: nil, order: nil)

        let descriptor = try XCTUnwrap(registry.descriptor(for: "db_a"))
        XCTAssertNil(descriptor.family)
        XCTAssertNil(descriptor.familyRole)
        XCTAssertNil(descriptor.familyNote)
        XCTAssertNil(descriptor.familyOrder)
    }

    /// 重复注册同 id（autoDiscover 重扫的等价路径）不能冲掉库族标注
    func testReRegisterKeepsFamilyFields() throws {
        let registry = DatabaseRegistry.shared
        registry.register(descriptor: makeDescriptor(id: "db_b"), url: fileURL("db_b.sqlite"))
        registry.setFamily(dbId: "db_b", family: "family-a", role: "role-2", note: "note-2", order: 1)

        // 模拟重扫：一个完全没带库族字段的新描述符
        registry.register(descriptor: makeDescriptor(id: "db_b", name: "Renamed"), url: fileURL("db_b.sqlite"))

        let descriptor = try XCTUnwrap(registry.descriptor(for: "db_b"))
        XCTAssertEqual(descriptor.name, "Renamed", "非库族字段应当被新描述符覆盖")
        XCTAssertEqual(descriptor.family, "family-a")
        XCTAssertEqual(descriptor.familyRole, "role-2")
        XCTAssertEqual(descriptor.familyNote, "note-2")
        XCTAssertEqual(descriptor.familyOrder, 1)
    }

    /// 新描述符显式带了库族字段时，以新值为准
    func testReRegisterWithExplicitFamilyOverrides() throws {
        let registry = DatabaseRegistry.shared
        registry.register(descriptor: makeDescriptor(id: "db_c"), url: fileURL("db_c.sqlite"))
        registry.setFamily(dbId: "db_c", family: "family-a", role: "role-3", note: "note-3", order: 100)

        registry.register(
            descriptor: makeDescriptor(id: "db_c", family: "family-b", familyRole: "role-9"),
            url: fileURL("db_c.sqlite")
        )

        let descriptor = try XCTUnwrap(registry.descriptor(for: "db_c"))
        XCTAssertEqual(descriptor.family, "family-b")
        XCTAssertEqual(descriptor.familyRole, "role-9")
        // 新描述符未提供的字段继续继承
        XCTAssertEqual(descriptor.familyNote, "note-3")
        XCTAssertEqual(descriptor.familyOrder, 100)
    }

    func testRegisterEncryptedKeepsFamilyFields() throws {
        let registry = DatabaseRegistry.shared
        registry.register(descriptor: makeDescriptor(id: "db_a"), url: fileURL("db_a.sqlite"))
        registry.setFamily(dbId: "db_a", family: "family-a", role: "role-1", note: "note-1", order: 0)

        registry.registerEncrypted(
            descriptor: makeDescriptor(id: "db_a", isEncrypted: true),
            url: fileURL("db_a.sqlite"),
            keyProvider: StaticKeyProvider(databaseId: "db_a", key: "x'\(String(repeating: "a", count: 96))'"),
            preparationSQL: ["PRAGMA cipher_plaintext_header_size = 32"]
        )

        let descriptor = try XCTUnwrap(registry.descriptor(for: "db_a"))
        XCTAssertTrue(descriptor.isEncrypted)
        XCTAssertEqual(descriptor.family, "family-a")
        XCTAssertEqual(descriptor.familyRole, "role-1")
        XCTAssertEqual(descriptor.familyNote, "note-1")
        XCTAssertEqual(descriptor.familyOrder, 0)
        XCTAssertEqual(registry.preparationSQL(for: "db_a"), ["PRAGMA cipher_plaintext_header_size = 32"])
    }

    func testUnregisterEncryptionKeepsFamilyAndOwnerDisplayName() throws {
        let registry = DatabaseRegistry.shared
        var descriptor = makeDescriptor(id: "db_a", isEncrypted: true)
        descriptor.ownership = .currentUser
        descriptor.ownerIdentifier = "uuid-1"
        descriptor.ownerDisplayName = "alice"
        descriptor.family = "family-a"
        descriptor.familyRole = "role-1"
        descriptor.familyNote = "note-1"
        descriptor.familyOrder = 0

        registry.registerEncrypted(
            descriptor: descriptor,
            url: fileURL("db_a.sqlite"),
            keyProvider: StaticKeyProvider(databaseId: "db_a", key: "passphrase")
        )

        registry.unregisterEncryption(for: "db_a")

        let updated = try XCTUnwrap(registry.descriptor(for: "db_a"))
        XCTAssertFalse(updated.isEncrypted)
        XCTAssertNil(updated.encryptionType)
        XCTAssertEqual(updated.ownership, .currentUser)
        XCTAssertEqual(updated.ownerIdentifier, "uuid-1")
        XCTAssertEqual(updated.ownerDisplayName, "alice", "ownerDisplayName 曾在此路径上被丢掉")
        XCTAssertEqual(updated.family, "family-a")
        XCTAssertEqual(updated.familyRole, "role-1")
        XCTAssertEqual(updated.familyNote, "note-1")
        XCTAssertEqual(updated.familyOrder, 0)
    }

    func testSetOwnershipKeepsFamilyFields() throws {
        let registry = DatabaseRegistry.shared
        registry.register(descriptor: makeDescriptor(id: "db_a"), url: fileURL("db_a.sqlite"))
        registry.setFamily(dbId: "db_a", family: "family-a", role: "role-1", note: "note-5", order: 0)

        registry.setOwnership(currentUserPathPrefix: tempDir.path)
        XCTAssertEqual(registry.descriptor(for: "db_a")?.family, "family-a")

        registry.setAllShared()
        XCTAssertEqual(registry.descriptor(for: "db_a")?.familyRole, "role-1")

        registry.setOwnership(dbId: "db_a", ownership: .otherUser)
        XCTAssertEqual(registry.descriptor(for: "db_a")?.familyNote, "note-5")

        registry.clearOwnership()
        XCTAssertEqual(registry.descriptor(for: "db_a")?.familyOrder, 0)
    }

    // MARK: - autoDiscover 重扫

    func testAutoDiscoverKeepsFamilyAndEncryptedFlag() throws {
        let registry = DatabaseRegistry.shared

        // 空文件：isEncryptedDatabase 的启发式判断会把它当成「未加密」
        let dbURL = fileURL("db_d.sqlite")
        FileManager.default.createFile(atPath: dbURL.path, contents: Data())

        let discovered = registry.autoDiscover(in: tempDir)
        let dbId = try XCTUnwrap(discovered.first)

        registry.registerEncrypted(
            descriptor: makeDescriptor(id: dbId, isEncrypted: true),
            url: dbURL,
            keyProvider: StaticKeyProvider(databaseId: "db_a", key: "passphrase")
        )
        registry.setFamily(dbId: dbId, family: "family-a", role: "role-4", note: "note-4", order: 101)

        // 再扫一次（WebUI 点刷新的等价路径）
        registry.autoDiscover(in: tempDir)

        let descriptor = try XCTUnwrap(registry.descriptor(for: dbId))
        XCTAssertTrue(descriptor.isEncrypted, "重扫不能把已注册的加密库降级成未加密")
        XCTAssertEqual(descriptor.encryptionType, "SQLCipher")
        XCTAssertEqual(descriptor.family, "family-a")
        XCTAssertEqual(descriptor.familyRole, "role-4")
        XCTAssertEqual(descriptor.familyNote, "note-4")
        XCTAssertEqual(descriptor.familyOrder, 101)
    }

    // MARK: - refreshHandler

    func testRefreshHandlerIsInvokedSynchronouslyOffMainThread() {
        var invocationCount = 0
        var wasMainThread = true

        DatabaseRegistry.shared.refreshHandler = {
            invocationCount += 1
            wasMainThread = Thread.isMainThread
        }

        DatabaseRegistry.shared.performRefresh()

        XCTAssertEqual(invocationCount, 1, "必须同步调用且只调用一次")
        XCTAssertFalse(wasMainThread, "契约要求在非主线程调用")
    }

    func testPerformRefreshWithoutHandlerIsNoop() {
        DatabaseRegistry.shared.refreshHandler = nil
        DatabaseRegistry.shared.performRefresh() // 不应崩溃
    }

    /// 回调内部可以安全地再调用 Registry 接口（不能因为持锁而死锁）
    func testRefreshHandlerCanCallRegistry() throws {
        DatabaseRegistry.shared.refreshHandler = { [self] in
            DatabaseRegistry.shared.register(descriptor: makeDescriptor(id: "late"), url: fileURL("late.sqlite"))
            DatabaseRegistry.shared.setFamily(dbId: "late", family: "family-a", role: "role-5", note: nil, order: 102)
        }

        DatabaseRegistry.shared.performRefresh()

        let descriptor = try XCTUnwrap(DatabaseRegistry.shared.descriptor(for: "late"))
        XCTAssertEqual(descriptor.familyRole, "role-5")
    }

    // MARK: - virtual / shadow 判定

    func testVirtualTableModuleParsing() {
        XCTAssertEqual(
            SQLiteInspector.virtualTableModule(
                fromCreateSQL: "CREATE VIRTUAL TABLE vt_a USING fts5(content, tokenize='trigram')"
            ),
            "fts5"
        )
        // 大小写与换行
        XCTAssertEqual(
            SQLiteInspector.virtualTableModule(fromCreateSQL: "create virtual table\n  geo\n  using RTREE(id, minX, maxX)"),
            "rtree"
        )
        // IF NOT EXISTS
        XCTAssertEqual(
            SQLiteInspector.virtualTableModule(fromCreateSQL: "CREATE VIRTUAL TABLE IF NOT EXISTS t USING fts4(a)"),
            "fts4"
        )
        // 无参数
        XCTAssertEqual(SQLiteInspector.virtualTableModule(fromCreateSQL: "CREATE VIRTUAL TABLE t USING dbstat"), "dbstat")
        // 普通表 / 空 sql
        XCTAssertNil(SQLiteInspector.virtualTableModule(fromCreateSQL: "CREATE TABLE table_a (id INTEGER PRIMARY KEY)"))
        XCTAssertNil(SQLiteInspector.virtualTableModule(fromCreateSQL: nil))
        // 列名里出现 using 不应误判
        XCTAssertNil(SQLiteInspector.virtualTableModule(fromCreateSQL: "CREATE TABLE t (using_flag INTEGER)"))
    }

    func testClassifyTablesMarksVirtualAndShadow() throws {
        let entries: [(name: String, sql: String?)] = [
            ("table_a", "CREATE TABLE table_a (id INTEGER PRIMARY KEY, body TEXT)"),
            ("vt_a", "CREATE VIRTUAL TABLE vt_a USING fts5(body, content='table_a')"),
            ("vt_a_data", "CREATE TABLE 'vt_a_data'(id INTEGER PRIMARY KEY, block BLOB)"),
            ("vt_a_idx", "CREATE TABLE 'vt_a_idx'(segid, term, pgno, PRIMARY KEY(segid, term))"),
            ("vt_a_content", "CREATE TABLE 'vt_a_content'(id INTEGER PRIMARY KEY, c0)"),
            ("vt_a_docsize", "CREATE TABLE 'vt_a_docsize'(id INTEGER PRIMARY KEY, sz BLOB)"),
            ("vt_a_config", "CREATE TABLE 'vt_a_config'(k PRIMARY KEY, v)"),
            // 后缀命中但没有对应的虚拟表父表 —— 必须仍然是普通表
            ("user_data", "CREATE TABLE user_data (id INTEGER)"),
            ("geo", "CREATE VIRTUAL TABLE geo USING rtree(id, minX, maxX)"),
            ("geo_node", "CREATE TABLE 'geo_node'(nodeno INTEGER PRIMARY KEY, data BLOB)"),
        ]

        let byName = Dictionary(
            uniqueKeysWithValues: SQLiteInspector.classifyTables(entries).map { ($0.name, $0) }
        )

        XCTAssertEqual(byName["table_a"]?.kind, .table)
        XCTAssertNil(byName["table_a"]?.module)

        XCTAssertEqual(byName["vt_a"]?.kind, .virtual)
        XCTAssertEqual(byName["vt_a"]?.module, "fts5")
        XCTAssertNil(byName["vt_a"]?.parentTable)

        for shadow in ["_data", "_idx", "_content", "_docsize", "_config"].map({ "vt_a\($0)" }) {
            XCTAssertEqual(byName[shadow]?.kind, .shadow, "\(shadow) 应判定为 shadow")
            XCTAssertEqual(byName[shadow]?.parentTable, "vt_a")
            XCTAssertNil(byName[shadow]?.module)
        }

        XCTAssertEqual(byName["user_data"]?.kind, .table, "没有名为 user 的虚拟表，user_data 不是影子表")
        XCTAssertNil(byName["user_data"]?.parentTable)

        XCTAssertEqual(byName["geo"]?.kind, .virtual)
        XCTAssertEqual(byName["geo"]?.module, "rtree")
        XCTAssertEqual(byName["geo_node"]?.kind, .shadow)
        XCTAssertEqual(byName["geo_node"]?.parentTable, "geo")
    }

    func testDBTableInfoDefaultsToPlainTable() {
        let info = DBTableInfo(name: "table_a", rowCount: 3)
        XCTAssertNil(info.kind)
        XCTAssertFalse(info.isShadow)
        XCTAssertFalse(info.isVirtual)
    }

    // MARK: - JSON 键名（WebUI 共享契约，逐字一致）

    func testDescriptorJSONKeys() throws {
        var descriptor = makeDescriptor(id: "db_a")
        descriptor.family = "family-a"
        descriptor.familyRole = "role-1"
        descriptor.familyNote = "note-1"
        descriptor.familyOrder = 0

        let data = try JSONEncoder().encode(descriptor)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["family"] as? String, "family-a")
        XCTAssertEqual(json["familyRole"] as? String, "role-1")
        XCTAssertEqual(json["familyNote"] as? String, "note-1")
        XCTAssertEqual(json["familyOrder"] as? Int, 0)
    }

    /// 未标注库族的旧行为：四个键整个不出现（Optional 缺省）
    func testDescriptorJSONOmitsAbsentFamilyKeys() throws {
        let data = try JSONEncoder().encode(makeDescriptor(id: "db_a"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(json["family"])
        XCTAssertNil(json["familyRole"])
        XCTAssertNil(json["familyNote"])
        XCTAssertNil(json["familyOrder"])
    }

    func testTableInfoJSONKeys() throws {
        let shadow = DBTableInfo(
            name: "vt_a_data",
            rowCount: nil,
            kind: DBTableKind.shadow.rawValue,
            parentTable: "vt_a"
        )
        let virtualTable = DBTableInfo(
            name: "vt_a",
            rowCount: 10,
            kind: DBTableKind.virtual.rawValue,
            module: "fts5"
        )

        let shadowJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(shadow)) as? [String: Any]
        )
        XCTAssertEqual(shadowJSON["kind"] as? String, "shadow")
        XCTAssertEqual(shadowJSON["parentTable"] as? String, "vt_a")
        XCTAssertNil(shadowJSON["module"])

        let virtualJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(virtualTable)) as? [String: Any]
        )
        XCTAssertEqual(virtualJSON["kind"] as? String, "virtual")
        XCTAssertEqual(virtualJSON["module"] as? String, "fts5")
        XCTAssertNil(virtualJSON["parentTable"])
    }
}

// MARK: - 真实数据库端到端（listTables / 跨表搜索）

extension DatabaseFamilyTests {
    /// 造一个带 FTS5 虚拟表的真实库
    private func makeFTSDatabase(at url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            throw XCTSkip("无法创建测试数据库")
        }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw XCTSkip("执行失败（系统 SQLite 可能未启用 FTS5）: \(sql)")
            }
        }

        try exec("CREATE TABLE table_a (id INTEGER PRIMARY KEY, body TEXT)")
        try exec("CREATE VIRTUAL TABLE vt_a USING fts5(body)")
        try exec("INSERT INTO table_a (body) VALUES ('hello probe')")
        try exec("INSERT INTO vt_a (body) VALUES ('hello probe')")
    }

    func testListTablesOnRealDatabaseMarksVirtualAndShadow() async throws {
        let dbURL = fileURL("fts.sqlite")
        try makeFTSDatabase(at: dbURL)

        DatabaseRegistry.shared.register(descriptor: makeDescriptor(id: "fts"), url: dbURL)

        let tables = try await SQLiteInspector.shared.listTables(dbId: "fts")
        let byName = Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0) })

        XCTAssertEqual(byName["table_a"]?.kind, "table")
        XCTAssertEqual(byName["vt_a"]?.kind, "virtual")
        XCTAssertEqual(byName["vt_a"]?.module, "fts5")

        let shadowTables = tables.filter(\.isShadow)
        XCTAssertFalse(shadowTables.isEmpty, "FTS5 应当产生影子表")
        for shadow in shadowTables {
            XCTAssertEqual(shadow.parentTable, "vt_a")
            XCTAssertTrue(shadow.name.hasPrefix("vt_a_"))
        }
    }

    func testSearchSkipsShadowTables() async throws {
        let dbURL = fileURL("fts-search.sqlite")
        try makeFTSDatabase(at: dbURL)

        DatabaseRegistry.shared.register(descriptor: makeDescriptor(id: "fts_search"), url: dbURL)

        let response = try await SQLiteInspector.shared.searchInDatabase(dbId: "fts_search", keyword: "hello")
        let hitNames = response.tableResults.map(\.tableName)

        XCTAssertTrue(hitNames.contains("table_a"), "普通表应当被搜到")
        for name in hitNames {
            XCTAssertFalse(
                name.hasPrefix("vt_a_"),
                "影子表 \(name) 不应出现在跨表搜索结果里"
            )
        }
    }
}
