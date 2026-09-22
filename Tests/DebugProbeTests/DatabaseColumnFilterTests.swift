// DatabaseColumnFilterTests.swift
// DebugProbeTests
//
// 覆盖列筛选下推契约：
// - filters 拼成 SQL WHERE，只返回命中的行
// - filteredTotalRows 是命中行数（分页页数按它算），totalRows 仍是整表行数
// - 没有筛选条件时 filteredTotalRows 为 nil
// - "null" 匹配 NULL 单元格，% 和 _ 按字面量匹配而不是通配符
// - 非法列名直接拒绝，不拼进 SQL
//

@testable import DebugProbe
import SQLite3
import XCTest

final class DatabaseColumnFilterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        DatabaseRegistry.shared.clear()

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugProbeFilterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        DatabaseRegistry.shared.clear()
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// 造一张 200 行的消息表：其中 3 行 group_id = 'target-group'
    private func makeMessagesDatabase(at url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            throw XCTSkip("无法创建测试数据库")
        }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw XCTSkip("执行失败: \(sql)")
            }
        }

        try exec("CREATE TABLE messages (id INTEGER PRIMARY KEY, group_id TEXT, body TEXT)")
        try exec("BEGIN")
        for index in 1...197 {
            try exec("INSERT INTO messages (group_id, body) VALUES ('group-\(index)', 'body \(index)')")
        }
        try exec("INSERT INTO messages (group_id, body) VALUES ('target-group', 'hit one')")
        try exec("INSERT INTO messages (group_id, body) VALUES ('target-group', 'hit two')")
        try exec("INSERT INTO messages (group_id, body) VALUES ('target-group', 'hit three')")
        // NULL 与通配符字面量各一行，用于校验筛选语义
        try exec("INSERT INTO messages (group_id, body) VALUES (NULL, '100% done')")
        try exec("INSERT INTO messages (group_id, body) VALUES ('plain', 'a_b')")
        try exec("INSERT INTO messages (group_id, body) VALUES ('plain', 'axb')")
        try exec("COMMIT")
    }

    private func registerMessagesDatabase(id: String = "msgs") throws -> String {
        let url = tempDir.appendingPathComponent("\(id).sqlite")
        try makeMessagesDatabase(at: url)

        let descriptor = DatabaseDescriptor(
            id: id,
            name: "Messages",
            kind: "sqlite",
            location: .custom(description: "\(id).sqlite"),
            isEncrypted: false
        )
        DatabaseRegistry.shared.register(descriptor: descriptor, url: url)
        return id
    }

    private func fetch(
        dbId: String,
        page: Int = 1,
        pageSize: Int = 50,
        filters: [DBColumnFilter]
    ) async throws -> DBTablePageResult {
        try await SQLiteInspector.shared.fetchTablePage(
            dbId: dbId,
            table: "messages",
            page: page,
            pageSize: pageSize,
            orderBy: nil,
            ascending: true,
            targetRowId: nil,
            filters: filters
        )
    }

    // MARK: - 筛选下推

    func testFilterReducesRowsAndPageCount() async throws {
        let dbId = try registerMessagesDatabase()

        let result = try await fetch(
            dbId: dbId,
            filters: [DBColumnFilter(column: "group_id", value: "target-group")]
        )

        // 命中 3 行：一页装得下，前面那些不命中的页不该再出现
        XCTAssertEqual(result.rows.count, 3)
        XCTAssertEqual(result.filteredTotalRows, 3)
        // totalRows 仍是整表行数，表列表里的行数显示不受筛选影响
        XCTAssertEqual(result.totalRows, 203)

        for row in result.rows {
            XCTAssertEqual(row.values["group_id"], "target-group")
        }
    }

    func testNoFilterLeavesFilteredTotalRowsNil() async throws {
        let dbId = try registerMessagesDatabase()

        let result = try await fetch(dbId: dbId, filters: [])

        XCTAssertNil(result.filteredTotalRows)
        XCTAssertEqual(result.totalRows, 203)
        XCTAssertEqual(result.rows.count, 50)
    }

    func testFilterIsContainsMatchAndCaseInsensitive() async throws {
        let dbId = try registerMessagesDatabase()

        let result = try await fetch(
            dbId: dbId,
            filters: [DBColumnFilter(column: "group_id", value: "TARGET")]
        )

        XCTAssertEqual(result.filteredTotalRows, 3)
        XCTAssertEqual(result.rows.count, 3)
    }

    func testFilteredPaginationWalksOnlyMatchedRows() async throws {
        let dbId = try registerMessagesDatabase()

        let firstPage = try await fetch(
            dbId: dbId,
            page: 1,
            pageSize: 2,
            filters: [DBColumnFilter(column: "group_id", value: "target-group")]
        )
        let secondPage = try await fetch(
            dbId: dbId,
            page: 2,
            pageSize: 2,
            filters: [DBColumnFilter(column: "group_id", value: "target-group")]
        )

        XCTAssertEqual(firstPage.rows.count, 2)
        XCTAssertEqual(secondPage.rows.count, 1)
        XCTAssertEqual(secondPage.filteredTotalRows, 3)
    }

    func testMultipleFiltersAreCombinedWithAnd() async throws {
        let dbId = try registerMessagesDatabase()

        let result = try await fetch(
            dbId: dbId,
            filters: [
                DBColumnFilter(column: "group_id", value: "target-group"),
                DBColumnFilter(column: "body", value: "hit t"),
            ]
        )

        XCTAssertEqual(result.filteredTotalRows, 2)
    }

    // MARK: - 筛选语义

    func testNullKeywordMatchesNullCells() async throws {
        let dbId = try registerMessagesDatabase()

        let result = try await fetch(
            dbId: dbId,
            filters: [DBColumnFilter(column: "group_id", value: "NULL")]
        )

        XCTAssertEqual(result.filteredTotalRows, 1)
        XCTAssertEqual(result.rows.first?.values["body"], "100% done")
    }

    func testWildcardCharactersAreMatchedLiterally() async throws {
        let dbId = try registerMessagesDatabase()

        // % 不能被当成 LIKE 通配符，否则会命中全部 203 行
        let percent = try await fetch(
            dbId: dbId,
            filters: [DBColumnFilter(column: "body", value: "100%")]
        )
        XCTAssertEqual(percent.filteredTotalRows, 1)

        // _ 不能被当成单字符通配符，否则 'axb' 也会命中
        let underscore = try await fetch(
            dbId: dbId,
            filters: [DBColumnFilter(column: "body", value: "a_b")]
        )
        XCTAssertEqual(underscore.filteredTotalRows, 1)
        XCTAssertEqual(underscore.rows.first?.values["body"], "a_b")
    }

    func testFilterOnNumericColumnMatchesTextRepresentation() async throws {
        let dbId = try registerMessagesDatabase()

        let result = try await fetch(
            dbId: dbId,
            filters: [DBColumnFilter(column: "id", value: "198")]
        )

        XCTAssertEqual(result.filteredTotalRows, 1)
        XCTAssertEqual(result.rows.first?.values["group_id"], "target-group")
    }

    // MARK: - 列名校验

    func testInvalidFilterColumnIsRejected() async throws {
        let dbId = try registerMessagesDatabase()

        do {
            _ = try await fetch(
                dbId: dbId,
                filters: [DBColumnFilter(column: "group_id\" OR 1=1 --", value: "x")]
            )
            XCTFail("非法列名应当被拒绝")
        } catch let error as DBInspectorError {
            guard case .invalidQuery = error else {
                return XCTFail("期望 invalidQuery，实际 \(error)")
            }
        }
    }
}
