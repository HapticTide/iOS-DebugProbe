// DatabasePlugin.swift
// DebugProbe
//
// Created by Sun on 2025/12/09.
// Copyright © 2025 Sun. All rights reserved.
//

import Foundation

// MARK: - Database Plugin

/// 数据库检查插件
/// 负责 SQLite 数据库的检查、查询等功能
public final class DatabasePlugin: DebugProbePlugin, @unchecked Sendable {
    // MARK: - Plugin Metadata

    public let pluginId: String = BuiltinPluginId.database
    public let displayName: String = "Database"
    public let version: String = "1.0.0"
    public let pluginDescription: String = "SQLite 数据库检查与查询"
    public let dependencies: [String] = []

    // MARK: - State

    public private(set) var state: PluginState = .uninitialized
    public private(set) var isEnabled: Bool = true

    // MARK: - Private Properties

    private weak var context: PluginContext?
    private let stateQueue = DispatchQueue(label: "com.sunimp.debugprobe.db.state")

    // MARK: - Lifecycle

    public init() {}

    public func initialize(context: PluginContext) {
        self.context = context

        // 从配置恢复状态
        if let enabled: Bool = context.getConfiguration(for: "database.enabled") {
            isEnabled = enabled
        }

        state = .stopped
        context.logInfo("DatabasePlugin initialized")
    }

    public func start() async throws {
        guard state != .running else { return }

        stateQueue.sync { state = .starting }

        // 数据库插件是被动响应式的，不需要主动采集
        // 只需要准备好响应查询命令即可

        stateQueue.sync { state = .running }
        context?.logInfo("DatabasePlugin started")
    }

    public func pause() async {
        guard state == .running else { return }
        stateQueue.sync { state = .paused }
        context?.logInfo("DatabasePlugin paused")
    }

    public func resume() async {
        guard state == .paused else { return }
        stateQueue.sync { state = .running }
        context?.logInfo("DatabasePlugin resumed")
    }

    public func stop() async {
        guard state == .running || state == .paused else { return }

        stateQueue.sync { state = .stopping }
        stateQueue.sync { state = .stopped }
        context?.logInfo("DatabasePlugin stopped")
    }

    public func handleCommand(_ command: PluginCommand) async {
        guard isEnabled else {
            sendErrorResponse(for: command, message: "Database plugin is disabled")
            return
        }

        switch command.commandType {
        case "enable":
            await enable()
            sendSuccessResponse(for: command)

        case "disable":
            await disable()
            sendSuccessResponse(for: command)

        case "db_command":
            await handleDBCommand(command)

        case "list_databases":
            await handleListDatabases(command)

        case "get_status":
            await handleGetStatus(command)

        default:
            sendErrorResponse(for: command, message: "Unknown command type: \(command.commandType)")
        }
    }

    // MARK: - Public Methods

    /// 启用数据库检查
    public func enable() async {
        isEnabled = true
        context?.setConfiguration(true, for: "database.enabled")

        if state == .paused {
            await resume()
        } else if state == .stopped {
            try? await start()
        }
    }

    /// 禁用数据库检查
    public func disable() async {
        isEnabled = false
        context?.setConfiguration(false, for: "database.enabled")

        if state == .running {
            await pause()
        }
    }

    /// 注册数据库
    /// - Parameters:
    ///   - path: 数据库文件路径
    ///   - name: 数据库显示名称
    ///   - description: 数据库描述
    public func registerDatabase(path: String, name: String, description: String? = nil) {
        let dbId = name.lowercased().replacingOccurrences(of: " ", with: "_")
        let descriptor = DatabaseDescriptor(
            id: dbId,
            name: name,
            kind: "sqlite",
            location: .custom(description: description ?? path)
        )
        if let url = URL(string: "file://\(path)") {
            DatabaseRegistry.shared.register(descriptor: descriptor, url: url)
        } else {
            _ = DatabaseRegistry.shared.register(descriptor: descriptor)
        }
        context?.logInfo("Registered database: \(name) at \(path)")
    }

    /// 注销数据库
    /// - Parameter dbId: 数据库 ID
    public func unregisterDatabase(dbId: String) {
        DatabaseRegistry.shared.unregister(id: dbId)
        context?.logInfo("Unregistered database: \(dbId)")
    }

    // MARK: - Command Handlers

    /// 处理数据库命令（与现有 DBCommand 兼容）
    private func handleDBCommand(_ command: PluginCommand) async {
        guard let payload = command.payload else {
            sendErrorResponse(for: command, message: "Missing payload")
            return
        }

        do {
            let dbCommand = try JSONDecoder().decode(DBCommand.self, from: payload)
            let response = await executeDBCommand(dbCommand)
            sendDBResponse(response, for: command)
        } catch {
            sendErrorResponse(for: command, message: "Invalid DB command: \(error)")
        }
    }

    /// 执行数据库命令
    private func executeDBCommand(_ command: DBCommand) async -> DBResponse {
        switch command.kind {
        case .listDatabases:
            return await listDatabases(requestId: command.requestId)

        case .listTables:
            guard let dbId = command.dbId else {
                return .failure(requestId: command.requestId, error: .databaseNotFound("dbId is nil"))
            }
            return await listTables(dbId: dbId, requestId: command.requestId)

        case .describeTable:
            guard let dbId = command.dbId, let tableName = command.table else {
                return .failure(requestId: command.requestId, error: .invalidQuery("Missing dbId or tableName"))
            }
            return await describeTable(dbId: dbId, tableName: tableName, requestId: command.requestId)

        case .fetchTablePage:
            guard let dbId = command.dbId, let tableName = command.table else {
                return .failure(requestId: command.requestId, error: .invalidQuery("Missing dbId or tableName"))
            }
            let page = command.page ?? 1
            let pageSize = command.pageSize ?? 50
            return await queryTable(
                dbId: dbId,
                tableName: tableName,
                page: page,
                pageSize: pageSize,
                orderBy: command.orderBy,
                ascending: command.ascending ?? true,
                requestId: command.requestId
            )

        case .executeQuery:
            guard let dbId = command.dbId, let sql = command.query else {
                return .failure(requestId: command.requestId, error: .invalidQuery("Missing dbId or sql"))
            }
            return await executeSQL(dbId: dbId, sql: sql, requestId: command.requestId)

        case .searchDatabase:
            guard let dbId = command.dbId, let keyword = command.keyword else {
                return .failure(requestId: command.requestId, error: .invalidQuery("Missing dbId or keyword"))
            }
            let maxResultsPerTable = command.maxResultsPerTable ?? 10
            return await searchDatabase(
                dbId: dbId,
                keyword: keyword,
                maxResultsPerTable: maxResultsPerTable,
                requestId: command.requestId
            )
        }
    }

    /// 列出所有已注册的数据库
    private func listDatabases(requestId: String) async -> DBResponse {
        do {
            let databases = try await SQLiteInspector.shared.listDatabases()
            return try .success(requestId: requestId, data: DBListDatabasesResponse(databases: databases))
        } catch {
            return .failure(requestId: requestId, error: .internalError(error.localizedDescription))
        }
    }

    /// 列出数据库中的所有表
    private func listTables(dbId: String, requestId: String) async -> DBResponse {
        do {
            let tables = try await SQLiteInspector.shared.listTables(dbId: dbId)
            return try .success(requestId: requestId, data: DBListTablesResponse(dbId: dbId, tables: tables))
        } catch let error as DBInspectorError {
            return .failure(requestId: requestId, error: error)
        } catch {
            return .failure(requestId: requestId, error: .internalError(error.localizedDescription))
        }
    }

    /// 获取表结构
    private func describeTable(dbId: String, tableName: String, requestId: String) async -> DBResponse {
        do {
            let columns = try await SQLiteInspector.shared.describeTable(dbId: dbId, table: tableName)
            return try .success(
                requestId: requestId,
                data: DBDescribeTableResponse(dbId: dbId, table: tableName, columns: columns)
            )
        } catch let error as DBInspectorError {
            return .failure(requestId: requestId, error: error)
        } catch {
            return .failure(requestId: requestId, error: .internalError(error.localizedDescription))
        }
    }

    /// 分页查询表数据
    private func queryTable(
        dbId: String,
        tableName: String,
        page: Int,
        pageSize: Int,
        orderBy: String?,
        ascending: Bool,
        requestId: String
    ) async -> DBResponse {
        do {
            let result = try await SQLiteInspector.shared.fetchTablePage(
                dbId: dbId,
                table: tableName,
                page: page,
                pageSize: pageSize,
                orderBy: orderBy,
                ascending: ascending
            )
            return try .success(requestId: requestId, data: result)
        } catch let error as DBInspectorError {
            return .failure(requestId: requestId, error: error)
        } catch {
            return .failure(requestId: requestId, error: .internalError(error.localizedDescription))
        }
    }

    /// 执行自定义 SQL
    private func executeSQL(dbId: String, sql: String, requestId: String) async -> DBResponse {
        do {
            let result = try await SQLiteInspector.shared.executeQuery(dbId: dbId, query: sql)
            return try .success(requestId: requestId, data: result)
        } catch let error as DBInspectorError {
            return .failure(requestId: requestId, error: error)
        } catch {
            return .failure(requestId: requestId, error: .internalError(error.localizedDescription))
        }
    }

    /// 跨表搜索数据库
    private func searchDatabase(
        dbId: String,
        keyword: String,
        maxResultsPerTable: Int,
        requestId: String
    ) async -> DBResponse {
        do {
            let result = try await SQLiteInspector.shared.searchInDatabase(
                dbId: dbId,
                keyword: keyword,
                maxResultsPerTable: maxResultsPerTable
            )
            return try .success(requestId: requestId, data: result)
        } catch let error as DBInspectorError {
            return .failure(requestId: requestId, error: error)
        } catch {
            return .failure(requestId: requestId, error: .internalError(error.localizedDescription))
        }
    }

    /// 列出数据库
    private func handleListDatabases(_ command: PluginCommand) async {
        do {
            let databases = try await SQLiteInspector.shared.listDatabases()
            let payload = try JSONEncoder().encode(databases)
            let response = PluginCommandResponse(
                pluginId: pluginId,
                commandId: command.commandId,
                success: true,
                payload: payload
            )
            context?.sendCommandResponse(response)
        } catch {
            sendErrorResponse(for: command, message: "Failed to list databases: \(error)")
        }
    }

    private func handleGetStatus(_ command: PluginCommand) async {
        let databases = DatabaseRegistry.shared.allDescriptors()
        let status = DatabasePluginStatus(
            isEnabled: isEnabled,
            state: state.rawValue,
            registeredDatabaseCount: databases.count
        )

        do {
            let payload = try JSONEncoder().encode(status)
            let response = PluginCommandResponse(
                pluginId: pluginId,
                commandId: command.commandId,
                success: true,
                payload: payload
            )
            context?.sendCommandResponse(response)
        } catch {
            sendErrorResponse(for: command, message: "Failed to encode status")
        }
    }

    // MARK: - Response Helpers

    private func sendDBResponse(_ dbResponse: DBResponse, for command: PluginCommand) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let payload = try encoder.encode(dbResponse)

            let response = PluginCommandResponse(
                pluginId: pluginId,
                commandId: command.commandId,
                success: dbResponse.success,
                payload: payload
            )
            context?.sendCommandResponse(response)
        } catch {
            sendErrorResponse(for: command, message: "Failed to encode DB response")
        }
    }

    private func sendSuccessResponse(for command: PluginCommand) {
        let response = PluginCommandResponse(
            pluginId: pluginId,
            commandId: command.commandId,
            success: true
        )
        context?.sendCommandResponse(response)
    }

    private func sendErrorResponse(for command: PluginCommand, message: String) {
        let response = PluginCommandResponse(
            pluginId: pluginId,
            commandId: command.commandId,
            success: false,
            errorMessage: message
        )
        context?.sendCommandResponse(response)
    }
}

// MARK: - Status DTO

/// 数据库插件状态
struct DatabasePluginStatus: Codable {
    let isEnabled: Bool
    let state: String
    let registeredDatabaseCount: Int
}
