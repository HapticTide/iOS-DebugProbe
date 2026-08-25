// DatabaseFamilyTests.swift
// DebugProbeTests
//
// 覆盖 1.2.6 新增的多库（库族）契约：
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
        registry.register(descriptor: makeDescriptor(id: "main"), url: fileURL("main.sqlite"))

        XCTAssertTrue(registry.setFamily(dbId: "main", family: "app", role: "主库", note: "不可再生 · 必须备份", order: 0))

        let descriptor = try XCTUnwrap(registry.descriptor(for: "main"))
        XCTAssertEqual(descriptor.family, "app")
        XCTAssertEqual(descriptor.familyRole, "主库")
        XCTAssertEqual(descriptor.familyNote, "不可再生 · 必须备份")
        XCTAssertEqual(descriptor.familyOrder, 0)
    }

    func testSetFamilyReturnsFalseForUnknownDatabase() {
        XCTAssertFalse(DatabaseRegistry.shared.setFamily(dbId: "not-registered", family: "app"))
    }

    func testSetFamilyWithNilClearsAnnotation() throws {
        let registry = DatabaseRegistry.shared
        registry.register(descriptor: makeDescriptor(id: "main"), url: fileURL("main.sqlite"))
        registry.setFamily(dbId: "main", family: "app", role: "主库", note: "备注", order: 0)

        registry.setFamily(dbId: "main", family: nil, role: nil, note: nil, order: nil)

        let descriptor = try XCTUnwrap(registry.descriptor(for: "main"))
        XCTAssertNil(descriptor.family)
        XCTAssertNil(descriptor.familyRole)
        XCTAssertNil(descriptor.familyNote)
        XCTAssertNil(descriptor.familyOrder)
    }

    /// 重复注册同 id（autoDiscover 重扫的等价路径）不能冲掉库族标注
    func testReRegisterKeepsFamilyFields() throws {
        let registry = DatabaseRegistry.shared
        registry.register(descriptor: makeDescriptor(id: "search_index"), url: fileURL("search_index.sqlite"))
        registry.setFamily(dbId: "search_index", family: "app", role: "FTS 索引", note: "可重建 · 不备份", order: 1)

        // 模拟重扫：一个完全没带库族字段的新描述符
        registry.register(descriptor: makeDescriptor(id: "search_index", name: "Search index"), url: fileURL("search_index.sqlite"))

        let descriptor = try XCTUnwrap(registry.descriptor(for: "search_index"))
        XCTAssertEqual(descriptor.name, "Search index", "非库族字段应当被新描述符覆盖")
        XCTAssertEqual(descriptor.family, "app")
        XCTAssertEqual(descriptor.familyRole, "FTS 索引")
        XCTAssertEqual(descriptor.familyNote, "可重建 · 不备份")
        XCTAssertEqual(descriptor.familyOrder, 1)
    }

    /// 新描述符显式带了库族字段时，以新值为准
    func testReRegisterWithExplicitFamilyOverrides() throws {
        let registry = DatabaseRegistry.shared
        registry.register(descriptor: makeDescriptor(id: "archive_0"), url: fileURL("archive_0.sqlite"))
        registry.setFamily(dbId: "archive_0", family: "app", role: "归档分片 0", note: "可再生", order: 100)

        registry.register(
            descriptor: makeDescriptor(id: "archive_0", family: "other", familyRole: "新角色"),
            url: fileURL("archive_0.sqlite")
        )

        let descriptor = try XCTUnwrap(registry.descriptor(for: "archive_0"))
        XCTAssertEqual(descriptor.family, "other")
        XCTAssertEqual(descriptor.familyRole, "新角色")
        // 新描述符未提供的字段继续继承
        XCTAssertEqual(descriptor.familyNote, "可再生")
        XCTAssertEqual(descriptor.familyOrder, 100)
    }

    func testRegisterEncryptedKeepsFamilyFields() throws {
        let registry = DatabaseRegistry.shared
        registry.register(descriptor: makeDescriptor(id: "main"), url: fileURL("main.sqlite"))
        registry.setFamily(dbId: "main", family: "app", role: "主库", note: "不可再生 · 必须备份", order: 0)

        registry.registerEncrypted(
            descriptor: makeDescriptor(id: "main", isEncrypted: true),
            url: fileURL("main.sqlite"),
            keyProvider: StaticKeyProvider(databaseId: "main", key: "x'\(String(repeating: "a", count: 96))'"),
            preparationSQL: ["PRAGMA cipher_plaintext_header_size = 32"]
        )

        let descriptor = try XCTUnwrap(registry.descriptor(for: "main"))
        XCTAssertTrue(descriptor.isEncrypted)
        XCTAssertEqual(descriptor.family, "app")
        XCTAssertEqual(descriptor.familyRole, "主库")
        XCTAssertEqual(descriptor.familyNote, "不可再生 · 必须备份")
        XCTAssertEqual(descriptor.familyOrder, 0)
        XCTAssertEqual(registry.preparationSQL(for: "main"), ["PRAGMA cipher_plaintext_header_size = 32"])
    }

    func testUnregisterEncryptionKeepsFamilyAndOwnerDisplayName() throws {
        let registry = DatabaseRegistry.shared
        var descriptor = makeDescriptor(id: "main", isEncrypted: true)
        descriptor.ownership = .currentUser
        descriptor.ownerIdentifier = "uuid-1"
        descriptor.ownerDisplayName = "alice"
        descriptor.family = "app"
        descriptor.familyRole = "主库"
        descriptor.familyNote = "不可再生 · 必须备份"
        descriptor.familyOrder = 0

        registry.registerEncrypted(
            descriptor: descriptor,
            url: fileURL("main.sqlite"),
            keyProvider: StaticKeyProvider(databaseId: "main", key: "passphrase")
        )

        registry.unregisterEncryption(for: "main")

        let updated = try XCTUnwrap(registry.descriptor(for: "main"))
        XCTAssertFalse(updated.isEncrypted)
        XCTAssertNil(updated.encryptionType)
        XCTAssertEqual(updated.ownership, .currentUser)
        XCTAssertEqual(updated.ownerIdentifier, "uuid-1")
        XCTAssertEqual(updated.ownerDisplayName, "alice", "ownerDisplayName 曾在此路径上被丢掉")
        XCTAssertEqual(updated.family, "app")
        XCTAssertEqual(updated.familyRole, "主库")
        XCTAssertEqual(updated.familyNote, "不可再生 · 必须备份")
        XCTAssertEqual(updated.familyOrder, 0)
    }

    func testSetOwnershipKeepsFamilyFields() throws {
        let registry = DatabaseRegistry.shared
        registry.register(descriptor: makeDescriptor(id: "main"), url: fileURL("main.sqlite"))
        registry.setFamily(dbId: "main", family: "app", role: "主库", note: "备注", order: 0)

        registry.setOwnership(currentUserPathPrefix: tempDir.path)
        XCTAssertEqual(registry.descriptor(for: "main")?.family, "app")

        registry.setAllShared()
        XCTAssertEqual(registry.descriptor(for: "main")?.familyRole, "主库")

        registry.setOwnership(dbId: "main", ownership: .otherUser)
        XCTAssertEqual(registry.descriptor(for: "main")?.familyNote, "备注")

        registry.clearOwnership()
        XCTAssertEqual(registry.descriptor(for: "main")?.familyOrder, 0)
    }

    // MARK: - autoDiscover 重扫

    func testAutoDiscoverKeepsFamilyAndEncryptedFlag() throws {
        let registry = DatabaseRegistry.shared

        // 空文件：isEncryptedDatabase 的启发式判断会把它当成「未加密」
        let dbURL = fileURL("archive_1.sqlite")
        FileManager.default.createFile(atPath: dbURL.path, contents: Data())

        let discovered = registry.autoDiscover(in: tempDir)
        let dbId = try XCTUnwrap(discovered.first)

        registry.registerEncrypted(
            descriptor: makeDescriptor(id: dbId, isEncrypted: true),
            url: dbURL,
            keyProvider: StaticKeyProvider(databaseId: "main", key: "passphrase")
        )
        registry.setFamily(dbId: dbId, family: "app", role: "归档分片 1", note: "可再生 · 不备份 · 无 FTS", order: 101)

        // 再扫一次（WebUI 点刷新的等价路径）
        registry.autoDiscover(in: tempDir)

        let descriptor = try XCTUnwrap(registry.descriptor(for: dbId))
        XCTAssertTrue(descriptor.isEncrypted, "重扫不能把已注册的加密库降级成未加密")
        XCTAssertEqual(descriptor.encryptionType, "SQLCipher")
        XCTAssertEqual(descriptor.family, "app")
        XCTAssertEqual(descriptor.familyRole, "归档分片 1")
        XCTAssertEqual(descriptor.familyNote, "可再生 · 不备份 · 无 FTS")
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
            DatabaseRegistry.shared.setFamily(dbId: "late", family: "app", role: "迟到的归档分片", note: nil, order: 102)
        }

        DatabaseRegistry.shared.performRefresh()

        let descriptor = try XCTUnwrap(DatabaseRegistry.shared.descriptor(for: "late"))
        XCTAssertEqual(descriptor.familyRole, "迟到的归档分片")
    }

    // MARK: - virtual / shadow 判定

    func testVirtualTableModuleParsing() {
        XCTAssertEqual(
            SQLiteInspector.virtualTableModule(
                fromCreateSQL: "CREATE VIRTUAL TABLE notes_fts USING fts5(content, tokenize='trigram')"
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
        XCTAssertNil(SQLiteInspector.virtualTableModule(fromCreateSQL: "CREATE TABLE notes (id INTEGER PRIMARY KEY)"))
        XCTAssertNil(SQLiteInspector.virtualTableModule(fromCreateSQL: nil))
        // 列名里出现 using 不应误判
        XCTAssertNil(SQLiteInspector.virtualTableModule(fromCreateSQL: "CREATE TABLE t (using_flag INTEGER)"))
    }

    func testClassifyTablesMarksVirtualAndShadow() throws {
        let entries: [(name: String, sql: String?)] = [
            ("notes", "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)"),
            ("notes_fts", "CREATE VIRTUAL TABLE notes_fts USING fts5(body, content='notes')"),
            ("notes_fts_data", "CREATE TABLE 'notes_fts_data'(id INTEGER PRIMARY KEY, block BLOB)"),
            ("notes_fts_idx", "CREATE TABLE 'notes_fts_idx'(segid, term, pgno, PRIMARY KEY(segid, term))"),
            ("notes_fts_content", "CREATE TABLE 'notes_fts_content'(id INTEGER PRIMARY KEY, c0)"),
            ("notes_fts_docsize", "CREATE TABLE 'notes_fts_docsize'(id INTEGER PRIMARY KEY, sz BLOB)"),
            ("notes_fts_config", "CREATE TABLE 'notes_fts_config'(k PRIMARY KEY, v)"),
            // 后缀命中但没有对应的虚拟表父表 —— 必须仍然是普通表
            ("user_data", "CREATE TABLE user_data (id INTEGER)"),
            ("geo", "CREATE VIRTUAL TABLE geo USING rtree(id, minX, maxX)"),
            ("geo_node", "CREATE TABLE 'geo_node'(nodeno INTEGER PRIMARY KEY, data BLOB)"),
        ]

        let byName = Dictionary(
            uniqueKeysWithValues: SQLiteInspector.classifyTables(entries).map { ($0.name, $0) }
        )

        XCTAssertEqual(byName["notes"]?.kind, .table)
        XCTAssertNil(byName["notes"]?.module)

        XCTAssertEqual(byName["notes_fts"]?.kind, .virtual)
        XCTAssertEqual(byName["notes_fts"]?.module, "fts5")
        XCTAssertNil(byName["notes_fts"]?.parentTable)

        for shadow in ["_data", "_idx", "_content", "_docsize", "_config"].map({ "notes_fts\($0)" }) {
            XCTAssertEqual(byName[shadow]?.kind, .shadow, "\(shadow) 应判定为 shadow")
            XCTAssertEqual(byName[shadow]?.parentTable, "notes_fts")
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
        let info = DBTableInfo(name: "notes", rowCount: 3)
        XCTAssertNil(info.kind)
        XCTAssertFalse(info.isShadow)
        XCTAssertFalse(info.isVirtual)
    }

    // MARK: - JSON 键名（WebUI 共享契约，逐字一致）

    func testDescriptorJSONKeys() throws {
        var descriptor = makeDescriptor(id: "main")
        descriptor.family = "app"
        descriptor.familyRole = "主库"
        descriptor.familyNote = "不可再生 · 必须备份"
        descriptor.familyOrder = 0

        let data = try JSONEncoder().encode(descriptor)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["family"] as? String, "app")
        XCTAssertEqual(json["familyRole"] as? String, "主库")
        XCTAssertEqual(json["familyNote"] as? String, "不可再生 · 必须备份")
        XCTAssertEqual(json["familyOrder"] as? Int, 0)
    }

    /// 未标注库族的旧行为：四个键整个不出现（Optional 缺省）
    func testDescriptorJSONOmitsAbsentFamilyKeys() throws {
        let data = try JSONEncoder().encode(makeDescriptor(id: "main"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(json["family"])
        XCTAssertNil(json["familyRole"])
        XCTAssertNil(json["familyNote"])
        XCTAssertNil(json["familyOrder"])
    }

    func testTableInfoJSONKeys() throws {
        let shadow = DBTableInfo(
            name: "notes_fts_data",
            rowCount: nil,
            kind: DBTableKind.shadow.rawValue,
            parentTable: "notes_fts"
        )
        let virtualTable = DBTableInfo(
            name: "notes_fts",
            rowCount: 10,
            kind: DBTableKind.virtual.rawValue,
            module: "fts5"
        )

        let shadowJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(shadow)) as? [String: Any]
        )
        XCTAssertEqual(shadowJSON["kind"] as? String, "shadow")
        XCTAssertEqual(shadowJSON["parentTable"] as? String, "notes_fts")
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

        try exec("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)")
        try exec("CREATE VIRTUAL TABLE notes_fts USING fts5(body)")
        try exec("INSERT INTO notes (body) VALUES ('hello probe')")
        try exec("INSERT INTO notes_fts (body) VALUES ('hello probe')")
    }

    func testListTablesOnRealDatabaseMarksVirtualAndShadow() async throws {
        let dbURL = fileURL("fts.sqlite")
        try makeFTSDatabase(at: dbURL)

        DatabaseRegistry.shared.register(descriptor: makeDescriptor(id: "fts"), url: dbURL)

        let tables = try await SQLiteInspector.shared.listTables(dbId: "fts")
        let byName = Dictionary(uniqueKeysWithValues: tables.map { ($0.name, $0) })

        XCTAssertEqual(byName["notes"]?.kind, "table")
        XCTAssertEqual(byName["notes_fts"]?.kind, "virtual")
        XCTAssertEqual(byName["notes_fts"]?.module, "fts5")

        let shadowTables = tables.filter(\.isShadow)
        XCTAssertFalse(shadowTables.isEmpty, "FTS5 应当产生影子表")
        for shadow in shadowTables {
            XCTAssertEqual(shadow.parentTable, "notes_fts")
            XCTAssertTrue(shadow.name.hasPrefix("notes_fts_"))
        }
    }

    func testSearchSkipsShadowTables() async throws {
        let dbURL = fileURL("fts-search.sqlite")
        try makeFTSDatabase(at: dbURL)

        DatabaseRegistry.shared.register(descriptor: makeDescriptor(id: "fts_search"), url: dbURL)

        let response = try await SQLiteInspector.shared.searchInDatabase(dbId: "fts_search", keyword: "hello")
        let hitNames = response.tableResults.map(\.tableName)

        XCTAssertTrue(hitNames.contains("notes"), "普通表应当被搜到")
        for name in hitNames {
            XCTAssertFalse(
                name.hasPrefix("notes_fts_"),
                "影子表 \(name) 不应出现在跨表搜索结果里"
            )
        }
    }
}
