// DBInspector.swift
// DebugProbe
//
// Created by Sun on 2025/12/05.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation

// MARK: - Data Models

/// 表类别
public enum DBTableKind: String, Codable, Sendable {
    /// 普通表
    case table
    /// 虚拟表（`CREATE VIRTUAL TABLE ... USING xxx(...)`）
    case virtual
    /// 虚拟表的影子表（FTS5 的 `_data`/`_idx`/... 等）
    case shadow
}

/// 表信息
public struct DBTableInfo: Codable, Sendable {
    public let name: String
    public let rowCount: Int?

    /// 表类别：`"table"` / `"virtual"` / `"shadow"`，缺省视为 `"table"`
    public let kind: String?

    /// 虚拟表的模块名（小写），如 `"fts5"`；非虚拟表为 nil
    public let module: String?

    /// 影子表所属的虚拟表名；非影子表为 nil
    public let parentTable: String?

    public init(
        name: String,
        rowCount: Int?,
        kind: String? = nil,
        module: String? = nil,
        parentTable: String? = nil
    ) {
        self.name = name
        self.rowCount = rowCount
        self.kind = kind
        self.module = module
        self.parentTable = parentTable
    }

    /// 是否为影子表（缺省视为普通表）
    public var isShadow: Bool { kind == DBTableKind.shadow.rawValue }

    /// 是否为虚拟表
    public var isVirtual: Bool { kind == DBTableKind.virtual.rawValue }
}

/// 列信息
public struct DBColumnInfo: Codable, Sendable {
    public let name: String
    public let type: String?
    public let notNull: Bool
    public let primaryKey: Bool
    public let defaultValue: String?

    public init(
        name: String,
        type: String?,
        notNull: Bool,
        primaryKey: Bool,
        defaultValue: String?
    ) {
        self.name = name
        self.type = type
        self.notNull = notNull
        self.primaryKey = primaryKey
        self.defaultValue = defaultValue
    }
}

/// 行数据
public struct DBRow: Codable, Sendable {
    public let values: [String: String?]

    public init(values: [String: String?]) {
        self.values = values
    }
}

/// 列筛选条件
///
/// 语义与 Web 端列筛选一致：对列值做大小写不敏感的包含匹配；
/// `value` 为 "null"（不区分大小写）时匹配 NULL 单元格。
public struct DBColumnFilter: Codable, Sendable, Equatable {
    public let column: String
    public let value: String

    public init(column: String, value: String) {
        self.column = column
        self.value = value
    }
}

/// 分页查询结果
public struct DBTablePageResult: Codable, Sendable {
    public let dbId: String
    public let table: String
    public let page: Int
    public let pageSize: Int
    public let totalRows: Int?
    /// 应用列筛选后的行数；没有筛选条件时为 nil
    ///
    /// 分页页数要按它算，`totalRows` 始终是整表行数
    public let filteredTotalRows: Int?
    public let columns: [DBColumnInfo]
    public let rows: [DBRow]

    public init(
        dbId: String,
        table: String,
        page: Int,
        pageSize: Int,
        totalRows: Int?,
        filteredTotalRows: Int? = nil,
        columns: [DBColumnInfo],
        rows: [DBRow]
    ) {
        self.dbId = dbId
        self.table = table
        self.page = page
        self.pageSize = pageSize
        self.totalRows = totalRows
        self.filteredTotalRows = filteredTotalRows
        self.columns = columns
        self.rows = rows
    }
}

/// 加密数据库的解锁状态
public enum EncryptionStatus: String, Codable, Sendable {
    /// 未加密（普通数据库）
    case none
    /// 加密且已解锁（有 keyProvider 且验证成功）
    case unlocked
    /// 加密但未解锁（无 keyProvider 或验证失败）
    case locked
}

/// 数据库信息（包含表数量）
public struct DBInfo: Codable, Sendable {
    public let descriptor: DatabaseDescriptor
    public let tableCount: Int
    public let fileSizeBytes: Int64?
    /// 数据库文件的绝对路径
    public let absolutePath: String?
    /// 加密状态
    public let encryptionStatus: EncryptionStatus

    public init(
        descriptor: DatabaseDescriptor,
        tableCount: Int,
        fileSizeBytes: Int64?,
        absolutePath: String? = nil,
        encryptionStatus: EncryptionStatus = .none
    ) {
        self.descriptor = descriptor
        self.tableCount = tableCount
        self.fileSizeBytes = fileSizeBytes
        self.absolutePath = absolutePath
        self.encryptionStatus = encryptionStatus
    }
}

// MARK: - Errors

/// DB Inspector 错误
public enum DBInspectorError: Error, Codable, Sendable {
    case databaseNotFound(String)
    case tableNotFound(String)
    case invalidQuery(String)
    case timeout
    case accessDenied(String)
    case internalError(String)

    public var message: String {
        switch self {
        case let .databaseNotFound(id):
            "Database not found: \(id)"
        case let .tableNotFound(name):
            "Table not found: \(name)"
        case let .invalidQuery(reason):
            "Invalid query: \(reason)"
        case .timeout:
            "Operation timeout"
        case let .accessDenied(reason):
            "Access denied: \(reason)"
        case let .internalError(msg):
            "Internal error: \(msg)"
        }
    }
}

// MARK: - Protocol

/// DB Inspector 协议
public protocol DBInspector: Sendable {
    /// 列出所有数据库
    func listDatabases() async throws -> [DBInfo]

    /// 列出指定数据库的所有表
    func listTables(dbId: String) async throws -> [DBTableInfo]

    /// 获取表结构
    func describeTable(dbId: String, table: String) async throws -> [DBColumnInfo]

    /// 分页获取表数据
    /// - Parameters:
    ///   - targetRowId: 可选的目标行 ID，传入时会自动计算并跳转到包含该行的页面
    ///   - filters: 列筛选条件，会下推成 SQL WHERE，分页与计数都只统计命中的行
    func fetchTablePage(
        dbId: String,
        table: String,
        page: Int,
        pageSize: Int,
        orderBy: String?,
        ascending: Bool,
        targetRowId: String?,
        filters: [DBColumnFilter]
    ) async throws -> DBTablePageResult
}
