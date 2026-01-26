// SQLiteInspector.swift
// DebugProbe
//
// Created by Sun on 2025/12/05.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation
import SQLite3

/// SQLite 数据库检查器实现
/// 使用原生 SQLite3 API，只读访问，支持 SQLCipher 加密数据库
public final class SQLiteInspector: DBInspector, @unchecked Sendable {
    /// 单例
    public static let shared = SQLiteInspector()

    /// 数据库注册表
    private let registry: DatabaseRegistry

    /// SQLite busy_timeout（毫秒）- 等待数据库锁的最大时间
    private let busyTimeout: Int32 = 5000 // 5 秒

    /// 查询执行超时（秒）- 超时后强制中断查询
    private let queryExecutionTimeout: TimeInterval = 10.0

    /// 单页最大行数
    private let maxPageSize = 500

    /// SQL 查询最大返回行数
    private let maxQueryRows = 1000

    private init(registry: DatabaseRegistry = .shared) {
        self.registry = registry
    }

    // MARK: - DBInspector Protocol

    public func listDatabases() async throws -> [DBInfo] {
        let descriptors = registry.allDescriptors()

        var results: [DBInfo] = []
        for descriptor in descriptors {
            guard let url = registry.url(for: descriptor.id) else { continue }

            // 先获取文件大小（不需要打开数据库）
            let fileSize = getFileSize(at: url)

            // 确定加密状态
            let encryptionStatus: EncryptionStatus = if !descriptor.isEncrypted {
                .none
            } else if registry.hasKeyProvider(for: descriptor.id) {
                .unlocked // 有 keyProvider，假定已解锁（实际验证在打开数据库时）
            } else {
                .locked // 无 keyProvider
            }

            do {
                let dbId = descriptor.id
                let tableCount = try await getTableCount(at: url, dbId: dbId)

                results.append(DBInfo(
                    descriptor: descriptor,
                    tableCount: tableCount,
                    fileSizeBytes: fileSize,
                    absolutePath: url.path,
                    encryptionStatus: encryptionStatus
                ))
            } catch {
                // 如果无法打开数据库，仍然显示它但标记为不可用
                // 文件大小仍然可以显示
                DebugLog.warning("[SQLiteInspector] getTableCount failed for \(descriptor.id): \(error)")

                // 如果打开失败且是加密数据库，标记为锁定
                let actualStatus: EncryptionStatus = if descriptor.isEncrypted {
                    .locked
                } else {
                    encryptionStatus
                }

                results.append(DBInfo(
                    descriptor: descriptor,
                    tableCount: 0,
                    fileSizeBytes: fileSize,
                    absolutePath: url.path,
                    encryptionStatus: actualStatus
                ))
            }
        }

        return results
    }

    public func listTables(dbId: String) async throws -> [DBTableInfo] {
        guard let url = registry.url(for: dbId) else {
            throw DBInspectorError.databaseNotFound(dbId)
        }

        // 检查敏感数据库
        if let descriptor = registry.descriptor(for: dbId), descriptor.isSensitive {
            throw DBInspectorError.accessDenied("Cannot inspect sensitive database")
        }

        // 检查加密数据库是否有密钥
        if
            let descriptor = registry.descriptor(for: dbId),
            descriptor.isEncrypted,
            !registry.hasKeyProvider(for: dbId) {
            throw DBInspectorError.accessDenied("Encrypted database requires key provider")
        }

        return try await queryTables(at: url, dbId: dbId)
    }

    public func describeTable(dbId: String, table: String) async throws -> [DBColumnInfo] {
        guard let url = registry.url(for: dbId) else {
            throw DBInspectorError.databaseNotFound(dbId)
        }

        // 检查敏感数据库
        if let descriptor = registry.descriptor(for: dbId), descriptor.isSensitive {
            throw DBInspectorError.accessDenied("Cannot inspect sensitive database")
        }

        // 检查加密数据库是否有密钥
        if
            let descriptor = registry.descriptor(for: dbId),
            descriptor.isEncrypted,
            !registry.hasKeyProvider(for: dbId) {
            throw DBInspectorError.accessDenied("Encrypted database requires key provider")
        }

        // 验证表名安全性
        guard isValidIdentifier(table) else {
            throw DBInspectorError.invalidQuery("Invalid table name")
        }

        return try await queryColumns(at: url, table: table, dbId: dbId)
    }

    public func fetchTablePage(
        dbId: String,
        table: String,
        page: Int,
        pageSize: Int,
        orderBy: String?,
        ascending: Bool
    ) async throws -> DBTablePageResult {
        guard let url = registry.url(for: dbId) else {
            throw DBInspectorError.databaseNotFound(dbId)
        }

        // 检查敏感数据库
        if let descriptor = registry.descriptor(for: dbId), descriptor.isSensitive {
            throw DBInspectorError.accessDenied("Cannot inspect sensitive database")
        }

        // 检查加密数据库是否有密钥
        if
            let descriptor = registry.descriptor(for: dbId),
            descriptor.isEncrypted,
            !registry.hasKeyProvider(for: dbId) {
            throw DBInspectorError.accessDenied("Encrypted database requires key provider")
        }

        // 验证表名安全性
        guard isValidIdentifier(table) else {
            throw DBInspectorError.invalidQuery("Invalid table name")
        }

        // 验证 orderBy 列名安全性
        if let orderBy, !isValidIdentifier(orderBy) {
            throw DBInspectorError.invalidQuery("Invalid column name for orderBy")
        }

        // 限制 pageSize
        let safePageSize = min(max(1, pageSize), maxPageSize)
        let safePage = max(1, page)

        return try await queryTablePage(
            at: url,
            dbId: dbId,
            table: table,
            page: safePage,
            pageSize: safePageSize,
            orderBy: orderBy,
            ascending: ascending
        )
    }

    /// 执行自定义 SQL 查询（只允许 SELECT）
    public func executeQuery(dbId: String, query: String) async throws -> DBQueryResponse {
        guard let url = registry.url(for: dbId) else {
            throw DBInspectorError.databaseNotFound(dbId)
        }

        // 检查敏感数据库
        if let descriptor = registry.descriptor(for: dbId), descriptor.isSensitive {
            throw DBInspectorError.accessDenied("Cannot query sensitive database")
        }

        // 检查加密数据库是否有密钥
        if
            let descriptor = registry.descriptor(for: dbId),
            descriptor.isEncrypted,
            !registry.hasKeyProvider(for: dbId) {
            throw DBInspectorError.accessDenied("Encrypted database requires key provider")
        }

        // 安全检查：只允许 SELECT 语句
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.uppercased().hasPrefix("SELECT") else {
            throw DBInspectorError.invalidQuery("Only SELECT statements are allowed")
        }

        // 检查是否包含危险操作（使用单词边界匹配，避免误判列名如 createTimestamp）
        let dangerousPatterns = ["DROP", "DELETE", "INSERT", "UPDATE", "ALTER", "CREATE", "ATTACH", "DETACH"]
        let upperQuery = trimmedQuery.uppercased()
        for pattern in dangerousPatterns {
            // 使用正则表达式进行单词边界匹配
            let regexPattern = "\\b\(pattern)\\b"
            if
                let regex = try? NSRegularExpression(pattern: regexPattern, options: []),
                regex
                    .firstMatch(
                        in: upperQuery,
                        options: [],
                        range: NSRange(upperQuery.startIndex..., in: upperQuery)
                    ) !=
                    nil {
                throw DBInspectorError.invalidQuery("Query contains forbidden operation: \(pattern)")
            }
        }

        return try await executeQueryInternal(at: url, dbId: dbId, query: trimmedQuery)
    }

    // MARK: - Private SQLite Operations

    /// 打开数据库（支持加密数据库）
    /// - Parameters:
    ///   - url: 数据库文件 URL
    ///   - dbId: 数据库 ID（用于查找密钥提供者）
    /// - Returns: SQLite 数据库指针
    private func openDatabase(at url: URL, dbId: String? = nil) async throws -> OpaquePointer {
        var db: OpaquePointer?

        // 以只读模式打开
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(url.path, &db, flags, nil)

        guard result == SQLITE_OK, let database = db else {
            if let db {
                sqlite3_close(db)
            }
            throw DBInspectorError.internalError("Failed to open database: \(result)")
        }

        // 设置 busy_timeout - 等待数据库锁的最大时间
        sqlite3_busy_timeout(database, busyTimeout)

        // 如果有 dbId，检查是否需要应用加密密钥
        if let dbId, let keyProvider = registry.keyProvider(for: dbId) {
            do {
                // 直接 await 获取密钥，无死锁风险
                let key = try await keyProvider.getKey()

                // 验证密钥格式
                guard isValidKeyFormat(key) else {
                    sqlite3_close(database)
                    throw DBInspectorError.accessDenied("Invalid encryption key format")
                }

                // 应用 SQLCipher 密钥
                // SQLCipher raw key 格式需要双引号包裹: "x'hex...'"
                let keySQL = "PRAGMA key = \"\(key)\""
                if sqlite3_exec(database, keySQL, nil, nil, nil) != SQLITE_OK {
                    let errorMessage = String(cString: sqlite3_errmsg(database))
                    sqlite3_close(database)
                    throw DBInspectorError.accessDenied("Failed to apply encryption key: \(errorMessage)")
                }

                // 执行注册时提供的准备语句（如 PRAGMA cipher_xxx 配置）
                let prepSQL = DatabaseRegistry.shared.preparationSQL(for: dbId)
                for sql in prepSQL {
                    if sqlite3_exec(database, sql, nil, nil, nil) != SQLITE_OK {
                        let errorMessage = String(cString: sqlite3_errmsg(database))
                        sqlite3_close(database)
                        throw DBInspectorError.accessDenied("Failed to execute preparation SQL: \(errorMessage)")
                    }
                }

                // 验证密钥是否正确（尝试读取 sqlite_master）
                let verifySQL = "SELECT count(*) FROM sqlite_master"
                if sqlite3_exec(database, verifySQL, nil, nil, nil) != SQLITE_OK {
                    let errorMessage = String(cString: sqlite3_errmsg(database))
                    sqlite3_close(database)
                    throw DBInspectorError.accessDenied("Invalid encryption key: \(errorMessage)")
                }

                DebugLog.debug("[SQLiteInspector] Successfully opened encrypted database: \(dbId)")
            } catch let error as DBInspectorError {
                throw error
            } catch {
                sqlite3_close(database)
                throw DBInspectorError.accessDenied("Failed to get encryption key: \(error.localizedDescription)")
            }
        }

        return database
    }

    /// 验证密钥格式
    /// - Parameter key: 密钥字符串
    /// - Returns: 密钥格式是否有效
    private func isValidKeyFormat(_ key: String) -> Bool {
        // SQLCipher 支持两种密钥格式：
        // 1. 普通字符串密码
        // 2. 十六进制 keyspec: x'...'（SQLCipher 4.x 默认 256-bit key + 128-bit salt = 48 bytes = 96 hex chars）
        if key.isEmpty {
            return false
        }

        // 如果是 hex keyspec 格式，验证长度和字符
        if key.hasPrefix("x'"), key.hasSuffix("'") {
            let hexPart = String(key.dropFirst(2).dropLast(1))
            // 验证是否为有效的十六进制字符串
            // SQLCipher 4.x: 96 hex chars (48 bytes)
            // SQLCipher 3.x: 64 hex chars (32 bytes)
            let validLengths = [64, 96]
            return validLengths.contains(hexPart.count) && hexPart.allSatisfy(\.isHexDigit)
        }

        // 普通字符串密码总是有效
        return true
    }

    private func getTableCount(at url: URL, dbId: String? = nil) async throws -> Int {
        let db = try await openDatabase(at: url, dbId: dbId)
        defer { sqlite3_close(db) }

        let sql = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBInspectorError.internalError("Failed to prepare statement")
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw DBInspectorError.internalError("Failed to execute query")
        }

        return Int(sqlite3_column_int(stmt, 0))
    }

    private func getFileSize(at url: URL) -> Int64? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
    }

    private func queryTables(at url: URL, dbId: String? = nil) async throws -> [DBTableInfo] {
        let db = try await openDatabase(at: url, dbId: dbId)
        defer { sqlite3_close(db) }

        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBInspectorError.internalError("Failed to prepare statement")
        }
        defer { sqlite3_finalize(stmt) }

        var tables: [DBTableInfo] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let namePtr = sqlite3_column_text(stmt, 0) else { continue }
            let name = String(cString: namePtr)

            // 获取行数
            let rowCount = try? getRowCount(db: db, table: name)

            tables.append(DBTableInfo(name: name, rowCount: rowCount))
        }

        return tables
    }

    private func getRowCount(db: OpaquePointer, table: String) throws -> Int {
        // 使用引号包裹表名
        let sql = "SELECT COUNT(*) FROM \"\(table)\""
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBInspectorError.internalError("Failed to count rows")
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw DBInspectorError.internalError("Failed to count rows")
        }

        return Int(sqlite3_column_int(stmt, 0))
    }

    private func queryColumns(at url: URL, table: String, dbId: String? = nil) async throws -> [DBColumnInfo] {
        let db = try await openDatabase(at: url, dbId: dbId)
        defer { sqlite3_close(db) }

        // 验证表是否存在
        guard try tableExists(db: db, table: table) else {
            throw DBInspectorError.tableNotFound(table)
        }

        let sql = "PRAGMA table_info(\"\(table)\")"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBInspectorError.internalError("Failed to prepare statement")
        }
        defer { sqlite3_finalize(stmt) }

        var columns: [DBColumnInfo] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let type = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let notNull = sqlite3_column_int(stmt, 3) != 0
            let defaultValue = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let primaryKey = sqlite3_column_int(stmt, 5) != 0

            columns.append(DBColumnInfo(
                name: name,
                type: type,
                notNull: notNull,
                primaryKey: primaryKey,
                defaultValue: defaultValue
            ))
        }

        return columns
    }

    private func queryTablePage(
        at url: URL,
        dbId: String,
        table: String,
        page: Int,
        pageSize: Int,
        orderBy: String?,
        ascending: Bool
    ) async throws -> DBTablePageResult {
        let db = try await openDatabase(at: url, dbId: dbId)
        defer { sqlite3_close(db) }

        // 验证表是否存在
        guard try tableExists(db: db, table: table) else {
            throw DBInspectorError.tableNotFound(table)
        }

        // 获取列信息
        let columns = try queryColumnsInternal(db: db, table: table)

        // 获取总行数
        let totalRows = try? getRowCount(db: db, table: table)

        // 构建查询 SQL
        var sql = "SELECT * FROM \"\(table)\""

        if let orderBy {
            sql += " ORDER BY \"\(orderBy)\" \(ascending ? "ASC" : "DESC")"
        }

        let offset = (page - 1) * pageSize
        sql += " LIMIT \(pageSize) OFFSET \(offset)"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBInspectorError.internalError("Failed to prepare statement")
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [DBRow] = []
        let columnCount = sqlite3_column_count(stmt)

        while sqlite3_step(stmt) == SQLITE_ROW {
            var values: [String: String?] = [:]

            for i in 0..<columnCount {
                let columnName = String(cString: sqlite3_column_name(stmt, i))
                let value = getColumnValue(stmt: stmt, index: i)
                values[columnName] = value
            }

            rows.append(DBRow(values: values))
        }

        return DBTablePageResult(
            dbId: dbId,
            table: table,
            page: page,
            pageSize: pageSize,
            totalRows: totalRows,
            columns: columns,
            rows: rows
        )
    }

    private func executeQueryInternal(at url: URL, dbId: String, query: String) async throws -> DBQueryResponse {
        let startTime = CFAbsoluteTimeGetCurrent()

        let db = try await openDatabase(at: url, dbId: dbId)
        defer { sqlite3_close(db) }

        // 设置超时定时器 - 超时后强制中断查询
        var timedOut = false
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            timedOut = true
            sqlite3_interrupt(db)
            DebugLog.warning("[DBInspector] Query timeout after \(queryExecutionTimeout)s, interrupted")
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + queryExecutionTimeout,
            execute: timeoutWorkItem
        )
        defer { timeoutWorkItem.cancel() }

        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, query, -1, &stmt, nil)

        if timedOut {
            sqlite3_finalize(stmt)
            throw DBInspectorError.timeout
        }

        guard prepareResult == SQLITE_OK else {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw DBInspectorError.invalidQuery(errorMessage)
        }
        defer { sqlite3_finalize(stmt) }

        // 获取列信息
        let columnCount = sqlite3_column_count(stmt)
        var columns: [DBColumnInfo] = []

        for i in 0..<columnCount {
            let name = String(cString: sqlite3_column_name(stmt, i))
            let type = sqlite3_column_decltype(stmt, i).map { String(cString: $0) }
            columns.append(DBColumnInfo(
                name: name,
                type: type,
                notNull: false,
                primaryKey: false,
                defaultValue: nil
            ))
        }

        // 执行查询并获取结果（限制最多 maxQueryRows 行）
        var rows: [DBRow] = []

        while !timedOut, rows.count < maxQueryRows {
            let stepResult = sqlite3_step(stmt)

            if timedOut {
                break
            }

            if stepResult == SQLITE_DONE {
                break
            } else if stepResult == SQLITE_ROW {
                var values: [String: String?] = [:]

                for i in 0..<columnCount {
                    let columnName = String(cString: sqlite3_column_name(stmt, i))
                    let value = getColumnValue(stmt: stmt, index: i)
                    values[columnName] = value
                }

                rows.append(DBRow(values: values))
            } else if stepResult == SQLITE_INTERRUPT {
                // 查询被中断（超时）
                break
            } else {
                // 其他错误
                let errorMessage = String(cString: sqlite3_errmsg(db))
                throw DBInspectorError.internalError("Query failed: \(errorMessage)")
            }
        }

        // 检查是否因超时而中断
        if timedOut {
            throw DBInspectorError.timeout
        }

        let executionTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000 // 转为毫秒

        return DBQueryResponse(
            dbId: dbId,
            query: query,
            columns: columns,
            rows: rows,
            rowCount: rows.count,
            executionTimeMs: executionTime
        )
    }

    private func queryColumnsInternal(db: OpaquePointer, table: String) throws -> [DBColumnInfo] {
        let sql = "PRAGMA table_info(\"\(table)\")"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBInspectorError.internalError("Failed to prepare statement")
        }
        defer { sqlite3_finalize(stmt) }

        var columns: [DBColumnInfo] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let type = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let notNull = sqlite3_column_int(stmt, 3) != 0
            let defaultValue = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let primaryKey = sqlite3_column_int(stmt, 5) != 0

            columns.append(DBColumnInfo(
                name: name,
                type: type,
                notNull: notNull,
                primaryKey: primaryKey,
                defaultValue: defaultValue
            ))
        }

        return columns
    }

    private func tableExists(db: OpaquePointer, table: String) throws -> Bool {
        let sql = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBInspectorError.internalError("Failed to check table existence")
        }
        defer { sqlite3_finalize(stmt) }

        // 使用 SQLITE_TRANSIENT 确保 SQLite 复制字符串
        // -1 表示使用 strlen 计算长度，SQLITE_TRANSIENT 告诉 SQLite 复制数据
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, table, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw DBInspectorError.internalError("Failed to check table existence")
        }

        return sqlite3_column_int(stmt, 0) > 0
    }

    private func getColumnValue(stmt: OpaquePointer?, index: Int32) -> String? {
        guard let stmt else { return nil }

        let type = sqlite3_column_type(stmt, index)

        switch type {
        case SQLITE_NULL:
            return nil
        case SQLITE_INTEGER:
            return String(sqlite3_column_int64(stmt, index))
        case SQLITE_FLOAT:
            return String(sqlite3_column_double(stmt, index))
        case SQLITE_TEXT:
            if let text = sqlite3_column_text(stmt, index) {
                return String(cString: text)
            }
            return nil
        case SQLITE_BLOB:
            let bytes = sqlite3_column_bytes(stmt, index)
            if let blob = sqlite3_column_blob(stmt, index) {
                let data = Data(bytes: blob, count: Int(bytes))
                return data.base64EncodedString()
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: - Validation

    /// 验证标识符（表名、列名）是否安全
    private func isValidIdentifier(_ identifier: String) -> Bool {
        // 只允许字母、数字、下划线
        // 不能以数字开头
        // 长度限制
        guard !identifier.isEmpty, identifier.count <= 128 else { return false }

        let pattern = "^[a-zA-Z_][a-zA-Z0-9_]*$"
        return identifier.range(of: pattern, options: .regularExpression) != nil
    }
}
