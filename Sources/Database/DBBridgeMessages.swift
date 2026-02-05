// DBBridgeMessages.swift
// DebugProbe
//
// Created by Sun on 2025/12/05.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation

// MARK: - DB Command

/// 数据库命令类型
public enum DBCommandKind: String, Codable, Sendable {
    case listDatabases
    case listTables
    case describeTable
    case fetchTablePage
    case executeQuery
    case searchDatabase // 跨表搜索
    case fetchRowsByRowIds // 按 rowid 批量取行（搜索结果分页）
}

/// 数据库命令
public struct DBCommand: Codable, Sendable {
    public let requestId: String
    public let kind: DBCommandKind
    public let dbId: String?
    public let table: String?
    public let page: Int?
    public let pageSize: Int?
    public let orderBy: String?
    public let ascending: Bool?
    public let query: String? // SQL 查询语句
    public let keyword: String? // 搜索关键词
    public let maxResultsPerTable: Int? // 每表最大结果数
    public let targetRowId: String? // 目标行 ID
    public let rowIds: [String]? // 批量 rowid

    public init(
        requestId: String,
        kind: DBCommandKind,
        dbId: String? = nil,
        table: String? = nil,
        page: Int? = nil,
        pageSize: Int? = nil,
        orderBy: String? = nil,
        ascending: Bool? = nil,
        query: String? = nil,
        keyword: String? = nil,
        maxResultsPerTable: Int? = nil,
        targetRowId: String? = nil,
        rowIds: [String]? = nil
    ) {
        self.requestId = requestId
        self.kind = kind
        self.dbId = dbId
        self.table = table
        self.page = page
        self.pageSize = pageSize
        self.orderBy = orderBy
        self.ascending = ascending
        self.query = query
        self.keyword = keyword
        self.maxResultsPerTable = maxResultsPerTable
        self.targetRowId = targetRowId
        self.rowIds = rowIds
    }
}

// MARK: - DB Response

/// 数据库响应
public struct DBResponse: Codable, Sendable {
    public let requestId: String
    public let success: Bool
    public let payload: Data?
    public let error: DBInspectorError?

    public init(requestId: String, success: Bool, payload: Data? = nil, error: DBInspectorError? = nil) {
        self.requestId = requestId
        self.success = success
        self.payload = payload
        self.error = error
    }

    /// 创建成功响应
    public static func success(requestId: String, data: some Encodable) throws -> DBResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(data)
        return DBResponse(requestId: requestId, success: true, payload: payload, error: nil)
    }

    /// 创建错误响应
    public static func failure(requestId: String, error: DBInspectorError) -> DBResponse {
        DBResponse(requestId: requestId, success: false, payload: nil, error: error)
    }
}

// MARK: - Response Payload Types

/// 数据库列表响应
public struct DBListDatabasesResponse: Codable, Sendable {
    public let databases: [DBInfo]

    public init(databases: [DBInfo]) {
        self.databases = databases
    }
}

/// 表列表响应
public struct DBListTablesResponse: Codable, Sendable {
    public let dbId: String
    public let tables: [DBTableInfo]

    public init(dbId: String, tables: [DBTableInfo]) {
        self.dbId = dbId
        self.tables = tables
    }
}

/// 表结构响应
public struct DBDescribeTableResponse: Codable, Sendable {
    public let dbId: String
    public let table: String
    public let columns: [DBColumnInfo]

    public init(dbId: String, table: String, columns: [DBColumnInfo]) {
        self.dbId = dbId
        self.table = table
        self.columns = columns
    }
}

/// SQL 查询响应
public struct DBQueryResponse: Codable, Sendable {
    public let dbId: String
    public let query: String
    public let columns: [DBColumnInfo]
    public let rows: [DBRow]
    public let rowCount: Int
    public let executionTimeMs: Double

    public init(
        dbId: String,
        query: String,
        columns: [DBColumnInfo],
        rows: [DBRow],
        rowCount: Int,
        executionTimeMs: Double
    ) {
        self.dbId = dbId
        self.query = query
        self.columns = columns
        self.rows = rows
        self.rowCount = rowCount
        self.executionTimeMs = executionTimeMs
    }
}

// MARK: - 跨表搜索响应

/// 单表搜索结果
public struct DBTableSearchResult: Codable, Sendable {
    /// 表名
    public let tableName: String
    /// 匹配的总行数
    public let matchCount: Int
    /// 匹配的列名列表
    public let matchedColumns: [String]
    /// 预览行（前 N 行匹配数据）
    public let previewRows: [DBRow]
    /// 所有匹配行的 rowid（升序）
    public let matchRowIds: [String]
    /// 表的列信息
    public let columns: [DBColumnInfo]

    public init(
        tableName: String,
        matchCount: Int,
        matchedColumns: [String],
        previewRows: [DBRow],
        matchRowIds: [String],
        columns: [DBColumnInfo]
    ) {
        self.tableName = tableName
        self.matchCount = matchCount
        self.matchedColumns = matchedColumns
        self.previewRows = previewRows
        self.matchRowIds = matchRowIds
        self.columns = columns
    }
}

/// 按 rowid 批量取行响应
public struct DBTableRowsResponse: Codable, Sendable {
    public let dbId: String
    public let table: String
    public let columns: [DBColumnInfo]
    public let rows: [DBRow]

    public init(dbId: String, table: String, columns: [DBColumnInfo], rows: [DBRow]) {
        self.dbId = dbId
        self.table = table
        self.columns = columns
        self.rows = rows
    }
}

/// 数据库搜索响应
public struct DBSearchResponse: Codable, Sendable {
    /// 数据库 ID
    public let dbId: String
    /// 搜索关键词
    public let keyword: String
    /// 各表的搜索结果
    public let tableResults: [DBTableSearchResult]
    /// 匹配的总行数
    public let totalMatches: Int
    /// 搜索耗时（毫秒）
    public let searchDurationMs: Double

    public init(
        dbId: String,
        keyword: String,
        tableResults: [DBTableSearchResult],
        totalMatches: Int,
        searchDurationMs: Double
    ) {
        self.dbId = dbId
        self.keyword = keyword
        self.tableResults = tableResults
        self.totalMatches = totalMatches
        self.searchDurationMs = searchDurationMs
    }
}
